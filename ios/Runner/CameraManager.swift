import AVFoundation
import UIKit
import Flutter
import Photos
import CoreMotion
import CoreImage

class CameraManager: NSObject {
    static let shared = CameraManager()

    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var isHDREnabled = false
    private var isRawEnabled = false
    private var isHdrPlusEnabled = false  // === BAGO: native HDR+ mode ===
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var lastPhotoCompletion: ((Result<[String: String], Error>) -> Void)?

    private var pendingRawURL: String?
    private var pendingJpegURL: String?
    private var expectedPhotoCount: Int = 1
    private var receivedPhotoCount: Int = 0
    private var captureError: Error?

    private var softwareZoomFactor: CGFloat = 1.0

    private let motionManager = CMMotionManager()
    private var currentPhysicalOrientation: UIDeviceOrientation = .portrait

    // Core Image context — reuse for performance (Metal-accelerated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func setup(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        sessionQueue.async {
            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                                for: .video,
                                                                position: .back) else {
                    throw NSError(domain: "Camera", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No back camera"])
                }
                self.device = backCamera

                let input = try AVCaptureDeviceInput(device: backCamera)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.input = input
                }

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true

                    if #available(iOS 13.0, *) {
                        self.photoOutput.maxPhotoQualityPrioritization = .quality
                    }
                }

                self.session.commitConfiguration()
                self.session.startRunning()

                self.startOrientationTracking()

                let caps = self.getCapabilities()
                DispatchQueue.main.async { completion(.success(caps)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func startOrientationTracking() {
        guard motionManager.isAccelerometerAvailable else { return }
        motionManager.accelerometerUpdateInterval = 0.2

        motionManager.startAccelerometerUpdates(to: OperationQueue()) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            let x = data.acceleration.x
            let y = data.acceleration.y

            var newOrientation: UIDeviceOrientation = self.currentPhysicalOrientation
            if abs(y) > abs(x) {
                newOrientation = y < 0 ? .portrait : .portraitUpsideDown
            } else {
                newOrientation = x > 0 ? .landscapeRight : .landscapeLeft
            }

            if newOrientation != self.currentPhysicalOrientation {
                self.currentPhysicalOrientation = newOrientation
            }
        }
    }

    func currentOrientationCode() -> Int {
        switch currentPhysicalOrientation {
        case .portrait: return 0
        case .landscapeRight: return 1
        case .portraitUpsideDown: return 2
        case .landscapeLeft: return 3
        default: return 0
        }
    }

    private func videoOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return .portrait
        }
    }

    func getCapabilities() -> [String: Any] {
        guard let d = device else { return [:] }
        let rawSupported = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty

        return [
            "minISO": d.activeFormat.minISO,
            "maxISO": d.activeFormat.maxISO,
            "minExposureDuration": CMTimeGetSeconds(d.activeFormat.minExposureDuration),
            "maxExposureDuration": CMTimeGetSeconds(d.activeFormat.maxExposureDuration),
            "minZoom": 1.0,
            "maxZoom": min(d.activeFormat.videoMaxZoomFactor, 10.0),
            "supportsHDR": d.activeFormat.isVideoHDRSupported,
            "supportsFocus": d.isFocusModeSupported(.locked),
            "supportsExposure": d.isExposureModeSupported(.custom),
            "supportsRAW": rawSupported,
        ]
    }

    func setISO(_ iso: Float, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }
        sessionQueue.async {
            do {
                try d.lockForConfiguration()
                let clamped = max(d.activeFormat.minISO, min(iso, d.activeFormat.maxISO))
                let currentDur = d.exposureDuration
                d.setExposureModeCustom(duration: currentDur, iso: clamped, completionHandler: nil)
                d.unlockForConfiguration()
                completion(true)
            } catch { completion(false) }
        }
    }

    func setShutterSpeed(_ seconds: Double, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }
        sessionQueue.async {
            do {
                try d.lockForConfiguration()
                let duration = CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000)
                let minDur = d.activeFormat.minExposureDuration
                let maxDur = d.activeFormat.maxExposureDuration
                let clamped = CMTimeMaximum(minDur, CMTimeMinimum(duration, maxDur))
                let currentISO = d.iso
                d.setExposureModeCustom(duration: clamped, iso: currentISO, completionHandler: nil)
                d.unlockForConfiguration()
                completion(true)
            } catch { completion(false) }
        }
    }

    func setExposureBias(_ bias: Float, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }
        sessionQueue.async {
            do {
                try d.lockForConfiguration()
                if d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposureMode = .continuousAutoExposure
                }
                let clamped = max(d.minExposureTargetBias, min(bias, d.maxExposureTargetBias))
                d.setExposureTargetBias(clamped, completionHandler: nil)
                d.unlockForConfiguration()
                completion(true)
            } catch { completion(false) }
        }
    }

    func setFocus(_ position: Float, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }
        sessionQueue.async {
            do {
                try d.lockForConfiguration()
                let clamped = max(0.0, min(position, 1.0))
                if d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
                } else {
                    d.focusMode = .locked
                }
                d.unlockForConfiguration()
                completion(true)
            } catch { completion(false) }
        }
    }

    func focusAtPoint(x: Float, y: Float, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }
        sessionQueue.async {
            do {
                try d.lockForConfiguration()
                let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                if d.isFocusPointOfInterestSupported {
                    d.focusPointOfInterest = point
                    d.focusMode = .autoFocus
                }
                if d.isExposurePointOfInterestSupported {
                    d.exposurePointOfInterest = point
                    d.exposureMode = .continuousAutoExposure
                }
                d.unlockForConfiguration()
                completion(true)
            } catch { completion(false) }
        }
    }

    func setZoom(_ factor: CGFloat, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }
        sessionQueue.async {
            let clamped = max(1.0, min(factor, d.activeFormat.videoMaxZoomFactor))
            self.softwareZoomFactor = clamped

            if self.isRawEnabled {
                completion(true)
                return
            }

            do {
                try d.lockForConfiguration()
                d.videoZoomFactor = clamped
                d.unlockForConfiguration()
                completion(true)
            } catch { completion(false) }
        }
    }

    func setRAW(_ enabled: Bool) {
        isRawEnabled = enabled
        guard let d = device else { return }

        sessionQueue.async {
            do {
                try d.lockForConfiguration()
                if enabled {
                    self.softwareZoomFactor = d.videoZoomFactor
                    d.videoZoomFactor = 1.0
                } else {
                    let target = max(1.0, min(self.softwareZoomFactor, d.activeFormat.videoMaxZoomFactor))
                    d.videoZoomFactor = target
                }
                d.unlockForConfiguration()
            } catch {
                print("⚠️ RAW toggle zoom sync error: \(error)")
            }
        }
    }

    func setFlashMode(_ mode: String) {
        switch mode {
        case "on": flashMode = .on
        case "auto": flashMode = .auto
        default: flashMode = .off
        }
    }

    func setHDR(_ enabled: Bool) { isHDREnabled = enabled }

    // === BAGONG: HDR+ toggle ===
    func setHdrPlus(_ enabled: Bool) {
        isHdrPlusEnabled = enabled
        print("🌈 Native HDR+ set to: \(enabled)")
    }

    var currentSoftwareZoom: CGFloat { softwareZoomFactor }
    var isInRawMode: Bool { isRawEnabled }

    func capturePhoto(completion: @escaping (Result<[String: String], Error>) -> Void) {
        sessionQueue.async {
            self.pendingRawURL = nil
            self.pendingJpegURL = nil
            self.receivedPhotoCount = 0
            self.captureError = nil
            self.lastPhotoCompletion = completion

            let orientation = self.videoOrientation(for: self.currentPhysicalOrientation)
            if let photoConnection = self.photoOutput.connection(with: .video) {
                if photoConnection.isVideoOrientationSupported {
                    photoConnection.videoOrientation = orientation
                }
            }

            var settings: AVCapturePhotoSettings

            if self.isRawEnabled,
               let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawFormat,
                    processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                )
                self.expectedPhotoCount = 2
                if #available(iOS 13.0, *) {
                    settings.photoQualityPrioritization = .speed
                }
                settings.isHighResolutionPhotoEnabled = false
                settings.isAutoStillImageStabilizationEnabled = false
            } else {
                settings = AVCapturePhotoSettings()
                self.expectedPhotoCount = 1
                settings.isHighResolutionPhotoEnabled = true
                if #available(iOS 13.0, *) {
                    settings.photoQualityPrioritization = .balanced
                }
                settings.isAutoStillImageStabilizationEnabled = self.isHDREnabled
            }

            if let d = self.device, d.hasFlash {
                settings.flashMode = self.flashMode
            }

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // === CORE IMAGE HDR PROCESSING ===
    // Ito ang core ng native HDR+. Kayang mag-work sa 12-14 bit sensor data
    // via Core Image's Metal-accelerated pipeline.
    //
    // Filters used:
    //   1. CIHighlightShadowAdjust — Apple's built-in tone mapping
    //      (lifts shadows, tames highlights, preserves colors)
    //   2. CIExposureAdjust — subtle exposure lift
    //   3. CIVibrance — konting color pop na hindi over-saturating
    //
    // All processing happens sa GPU via Metal, ~200-300ms lang.
    private func applyNativeHDR(imageData: Data) -> Data? {
        guard let ciImage = CIImage(data: imageData) else {
            print("⚠️ Could not create CIImage from data")
            return imageData
        }

        // Layer 1: Highlight/Shadow adjustment (Apple's HDR filter)
        var processed = ciImage
        if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            // -1.0 to +1.0 range. Negative = dim highlights, positive = lift.
            filter.setValue(-0.3, forKey: "inputHighlightAmount")   // Dim bright areas by 30%
            filter.setValue(0.5, forKey: "inputShadowAmount")       // Lift shadows by 50%
            filter.setValue(2.0, forKey: "inputRadius")             // Local adjustment radius
            if let output = filter.outputImage {
                processed = output
            }
        }

        // Layer 2: Subtle exposure boost (very slight)
        if let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            filter.setValue(0.1, forKey: kCIInputEVKey)  // +0.1 EV = very subtle lift
            if let output = filter.outputImage {
                processed = output
            }
        }

        // Layer 3: Konting vibrance (natural color enhancement, NOT saturation)
        // Vibrance protects skin tones, unlike saturation
        if let filter = CIFilter(name: "CIVibrance") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            filter.setValue(0.15, forKey: "inputAmount")  // Subtle 15% vibrance
            if let output = filter.outputImage {
                processed = output
            }
        }

        // Render to JPEG data via GPU
        guard let cgImage = ciContext.createCGImage(processed, from: processed.extent) else {
            print("⚠️ Failed to render CIImage to CGImage")
            return imageData
        }

        // Encode as JPEG with 92% quality
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.92)
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            captureError = error
            checkAndComplete()
            return
        }

        let isRawPhoto = photo.isRawPhoto
        let ext = isRawPhoto ? "dng" : "jpg"

        guard var photoData = photo.fileDataRepresentation() else {
            captureError = NSError(domain: "Camera", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No photo data"])
            checkAndComplete()
            return
        }

        // === Apply native HDR+ processing kung enabled AT JPEG (hindi RAW) ===
        // Yung RAW/DNG ay hindi natin ino-touch — pristine sya for Lightroom.
        if isHdrPlusEnabled && !isRawPhoto {
            print("🌈 Applying native Core Image HDR+...")
            if let hdrData = applyNativeHDR(imageData: photoData) {
                photoData = hdrData
                print("✅ Native HDR+ applied via Core Image (GPU)")
            }
        }

        let tmpDir = NSTemporaryDirectory()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = isRawPhoto ? "_raw" : ""
        let filename = "manualcam_\(timestamp)\(suffix).\(ext)"
        let filePath = (tmpDir as NSString).appendingPathComponent(filename)

        do {
            try photoData.write(to: URL(fileURLWithPath: filePath))
            if isRawPhoto {
                pendingRawURL = filePath
            } else {
                pendingJpegURL = filePath
            }
        } catch {
            captureError = error
        }

        checkAndComplete()
    }

    private func checkAndComplete() {
        receivedPhotoCount += 1

        if receivedPhotoCount >= expectedPhotoCount || captureError != nil {
            DispatchQueue.main.async {
                if let error = self.captureError {
                    self.lastPhotoCompletion?(.failure(error))
                } else {
                    var paths: [String: String] = [:]
                    if let jpeg = self.pendingJpegURL { paths["jpeg"] = jpeg }
                    if let raw = self.pendingRawURL { paths["raw"] = raw }
                    paths["_softwareZoom"] = String(format: "%.2f", self.softwareZoomFactor)
                    self.lastPhotoCompletion?(.success(paths))
                }
                self.lastPhotoCompletion = nil
            }
        }
    }
}
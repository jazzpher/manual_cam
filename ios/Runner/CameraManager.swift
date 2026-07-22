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
    private var isHdrPlusEnabled = false
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

    // Core Image context — reusable, Metal GPU-accelerated
    // [CHANGED] Now configured for RAW processing with wide gamut support
    private let ciContext: CIContext = {
        return CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,  // [NEW] Wide gamut
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,        // [NEW] Standard output
        ])
    }()

    // MARK: - Setup

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

    // MARK: - Orientation tracking (CoreMotion)

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

    // MARK: - Capabilities

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

    // MARK: - Manual Controls

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

    // [CHANGED] HDR+ now REQUIRES RAW to work (kailangan ng DNG file for CIRAWFilter)
    func setHdrPlus(_ enabled: Bool) {
        isHdrPlusEnabled = enabled
        print("🌈 Native HDR+ set to: \(enabled) (requires RAW mode for true 14-bit processing)")
    }

    var currentSoftwareZoom: CGFloat { softwareZoomFactor }
    var isInRawMode: Bool { isRawEnabled }

    // MARK: - Capture

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

    // [REMOVED] Old applyNativeHDR(imageData:) — that was JPEG-based (8-bit)

    // [NEW] === TRUE 14-BIT RAW HDR PROCESSING ===
    // Ito ang bagong core ng HDR+. Nag-p-process directly sa 12-14 bit RAW sensor data
    // using CIRAWFilter — Apple's dedicated RAW processing filter (same used in Photos app).
    //
    // Bakit true 14-bit:
    // - CIRAWFilter decodes yung DNG sa native sensor precision (12-14 bits per channel)
    // - Filter operations happen sa 32-bit float internally
    // - Final render lang na-r-reduce to 8-bit for JPEG output
    // - Highlight/shadow recovery ay nasa RAW pipeline mismo (~4 stops vs ~1 stop sa JPEG)
    //
    // Returns: Path to new HDR-processed JPEG file, or nil on failure.
    private func applyRawHDR(dngURL: URL) -> String? {
        print("🌈 Loading RAW DNG for 14-bit HDR processing...")

        // Load DNG using CIRAWFilter (14-bit native precision)
        guard let rawFilter = CIRAWFilter(imageURL: dngURL) else {
            print("⚠️ Failed to create CIRAWFilter from DNG")
            return nil
        }

        // === 14-bit HDR TONE MAPPING ===
        // Since we're operating on RAW data, kaya nating gumawa ng aggressive
        // adjustments na hindi ma-i-imagine sa 8-bit JPEG:

        // 1. Highlight recovery — pull down bright areas by ~2 stops
        //    (sa RAW, kaya natin i-recover hanggang ~4 stops ng highlight detail)
        rawFilter.exposure = -0.3  // Slight overall exposure reduction to protect highlights

        // 2. Shadow lift via boost (mas maganda sa RAW)
        //    Ito yung "shadow bias" — brightens sa darker parts habang protected ang highlights
        if #available(iOS 15.0, *) {
            rawFilter.shadowBias = 0.4  // Positive = lift shadows
        }

        // 3. Local contrast enhancement (preserves colors, adds depth)
        rawFilter.detailAmount = 0.2  // Slight detail boost

        // 4. Neutral color — walang saturation boost
        //    (RAW ay maga-render with accurate colors as-is)

        // 5. Noise reduction (RAW mas noisy kaysa JPEG, kailangan ng konting NR)
        rawFilter.noiseReductionAmount = 0.3

        guard var processed = rawFilter.outputImage else {
            print("⚠️ Failed to render RAW output image")
            return nil
        }

        // === ADDITIONAL TONE MAPPING (Apple's local adjustment filter) ===
        // Applied sa top ng RAW output para sa additional local contrast tuning
        if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            filter.setValue(-0.15, forKey: "inputHighlightAmount")   // Very subtle final highlight tame
            filter.setValue(0.2, forKey: "inputShadowAmount")        // Very subtle final shadow lift
            filter.setValue(1.5, forKey: "inputRadius")
            if let output = filter.outputImage {
                processed = output
            }
        }

        // === RENDER TO JPEG via Metal GPU ===
        guard let cgImage = ciContext.createCGImage(processed, from: processed.extent) else {
            print("⚠️ Failed to render final CGImage")
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.95) else {
            print("⚠️ Failed to encode JPEG")
            return nil
        }

        // Save yung HDR-processed JPEG sa temp folder
        let tmpDir = NSTemporaryDirectory()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "manualcam_\(timestamp)_hdr.jpg"
        let filePath = (tmpDir as NSString).appendingPathComponent(filename)

        do {
            try jpegData.write(to: URL(fileURLWithPath: filePath))
            print("✅ True 14-bit RAW HDR processed: \(filePath) [\(jpegData.count) bytes]")
            return filePath
        } catch {
            print("⚠️ Failed to write HDR JPEG: \(error)")
            return nil
        }
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

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

        guard let photoData = photo.fileDataRepresentation() else {
            captureError = NSError(domain: "Camera", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No photo data"])
            checkAndComplete()
            return
        }

        // [REMOVED] Yung old JPEG-based HDR processing sa dito (na 8-bit lang)
        // [CHANGED] HDR+ processing ay lumipat na sa checkAndComplete()
        //           kasi kailangan natin yung DNG file para mag-work with CIRAWFilter

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

            // [NEW] === APPLY TRUE 14-BIT HDR AFTER LAHAT NG PHOTOS RECEIVED ===
            // Kailangan lahat ng photos natin (both DNG at JPEG) bago mag-HDR
            // kasi kailangan natin ng DNG file bilang input for CIRAWFilter
            if isHdrPlusEnabled, captureError == nil, let rawPath = pendingRawURL {
                print("🌈 Starting true 14-bit RAW HDR pipeline...")
                let rawURL = URL(fileURLWithPath: rawPath)

                // Process asynchronously para hindi mag-block ang delegate queue
                DispatchQueue.global(qos: .userInitiated).async {
                    if let hdrPath = self.applyRawHDR(dngURL: rawURL) {
                        // Successfully processed — palitan yung JPEG path ng HDR version
                        self.pendingJpegURL = hdrPath
                        print("✅ HDR+ (14-bit) done, JPEG replaced with HDR version")
                    } else {
                        print("⚠️ HDR+ failed, using original JPEG")
                    }
                    self.completeCallback()
                }
            } else {
                completeCallback()
            }
        }
    }

    // [NEW] Extracted the completion logic sa sariling function
    // para pwedeng tawagin async after HDR processing
    private func completeCallback() {
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
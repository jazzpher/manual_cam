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
    // Configured for wide gamut internal processing, sRGB output for JPEG
    private let ciContext: CIContext = {
        return CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
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

    // HDR+ now requires RAW to work (kailangan ng DNG file for CIRAWFilter)
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

    // [NEW] === ADAPTIVE HDR VALUES via HISTOGRAM ANALYSIS ===
    // Analyze scene brightness using downsampled image + area average.
    // Returns tuple: (exposure adjustment, shadow bias, detail amount)
    //
    // Logic:
    //   - Dark scene (mean < 60): mag-lift lang ng shadows, minimal highlight recovery
    //   - Bright scene (mean > 180): aggressive highlight recovery
    //   - Balanced scene (60-180): moderate both
    private func analyzeScene(_ ciImage: CIImage) -> (exposure: Float, shadowBias: Float, detailAmount: Float) {
        // Downsample to tiny size para mabilis mag-analyze (yung pixel average lang naman ang kailangan)
        let extent = ciImage.extent

        // Use CIAreaAverage filter — GPU-accelerated single-pixel output
        guard let filter = CIFilter(name: "CIAreaAverage") else {
            return (-0.3, 0.4, 0.2)  // Fallback to defaults
        }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)

        guard let output = filter.outputImage else {
            return (-0.3, 0.4, 0.2)
        }

        // Render single pixel to get average RGB
        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(output,
                         toBitmap: &bitmap,
                         rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8,
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        // Compute luminance (BT.601 weights)
        let r = Float(bitmap[0])
        let g = Float(bitmap[1])
        let b = Float(bitmap[2])
        let meanBrightness = (0.299 * r + 0.587 * g + 0.114 * b)  // 0-255

        print("📊 Scene analysis: mean brightness = \(meanBrightness) / 255")

        // Adaptive value curves
        var exposure: Float
        var shadowBias: Float
        var detailAmount: Float

        if meanBrightness < 60 {
            // DARK SCENE — need mas maraming shadow lift, minimal highlight recovery
            // Halimbawa: indoor low-light, night shots
            let darkness = (60 - meanBrightness) / 60  // 0-1, more dark = higher
            exposure = -0.1 * (1.0 - darkness)         // 0 to -0.1 (mas kaunting recovery)
            shadowBias = 0.4 + 0.4 * darkness          // 0.4 to 0.8 (aggressive lift)
            detailAmount = 0.15 + 0.15 * darkness      // 0.15 to 0.3
            print("🌑 Dark scene detected: exposure=\(exposure), shadow=\(shadowBias)")
        } else if meanBrightness > 180 {
            // BRIGHT SCENE — need aggressive highlight recovery
            // Halimbawa: outdoor daylight, snow, beach
            let brightness = (meanBrightness - 180) / 75  // 0-1, more bright = higher
            let brightnessCapped = min(brightness, 1.0)
            exposure = -0.3 - 0.5 * brightnessCapped   // -0.3 to -0.8 (aggressive dim)
            shadowBias = 0.3 - 0.1 * brightnessCapped  // 0.3 to 0.2 (moderate lift)
            detailAmount = 0.2 + 0.1 * brightnessCapped
            print("☀️ Bright scene detected: exposure=\(exposure), shadow=\(shadowBias)")
        } else {
            // BALANCED SCENE — moderate values (yung dating hardcoded)
            exposure = -0.3
            shadowBias = 0.4
            detailAmount = 0.2
            print("⚖️ Balanced scene: using default HDR values")
        }

        return (exposure, shadowBias, detailAmount)
    }

    // === TRUE 14-BIT RAW HDR PROCESSING ===
    // Requires iOS 15.0+ (CIRAWFilter API)
    //
    // [CHANGED] Now uses adaptive HDR values via histogram analysis
    // [NEW] GPU-based center-crop kung naka-zoom (dating sa Dart pa, mabagal)
    @available(iOS 15.0, *)
    private func applyRawHDR(dngURL: URL) -> String? {
        print("🌈 Loading RAW DNG for 14-bit HDR processing...")

        guard let rawFilter = CIRAWFilter(imageURL: dngURL) else {
            print("⚠️ Failed to create CIRAWFilter from DNG")
            return nil
        }

        // First pass — get initial RAW output for scene analysis (before adjustments)
        guard let initialOutput = rawFilter.outputImage else {
            print("⚠️ Failed to get initial RAW output for analysis")
            return nil
        }

        // [NEW] Analyze scene brightness for adaptive HDR
        let (exposure, shadowBias, detailAmount) = analyzeScene(initialOutput)

        // Apply adaptive tone mapping
        rawFilter.exposure = exposure
        rawFilter.shadowBias = shadowBias
        rawFilter.detailAmount = detailAmount

        guard var processed = rawFilter.outputImage else {
            print("⚠️ Failed to render RAW output image")
            return nil
        }

        // Additional local tone mapping (Apple's CIHighlightShadowAdjust)
        // Very subtle — mainly for local contrast tuning after RAW pipeline
        if let filter = CIFilter(name: "CIHighlightShadowAdjust") {
            filter.setValue(processed, forKey: kCIInputImageKey)
            filter.setValue(-0.15, forKey: "inputHighlightAmount")
            filter.setValue(0.2, forKey: "inputShadowAmount")
            filter.setValue(1.5, forKey: "inputRadius")
            if let output = filter.outputImage {
                processed = output
            }
        }

        // [NEW] === GPU-BASED SOFTWARE ZOOM CROP ===
        // Kung naka-zoom > 1.0x, center-crop ang final image sa Swift side
        // (mas mabilis kaysa Dart image package na CPU-bound)
        if self.softwareZoomFactor > 1.01 {
            let cropFactor = 1.0 / self.softwareZoomFactor
            let extent = processed.extent
            let cropWidth = extent.width * cropFactor
            let cropHeight = extent.height * cropFactor
            let cropX = extent.origin.x + (extent.width - cropWidth) / 2.0
            let cropY = extent.origin.y + (extent.height - cropHeight) / 2.0

            let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
            processed = processed.cropped(to: cropRect)
            print("📸 GPU crop applied: \(self.softwareZoomFactor)x zoom, target rect=\(cropRect)")
        }

        // Render to JPEG via Metal GPU
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

            // APPLY TRUE 14-BIT HDR AFTER LAHAT NG PHOTOS RECEIVED
            if isHdrPlusEnabled, captureError == nil, let rawPath = pendingRawURL {
                if #available(iOS 15.0, *) {
                    print("🌈 Starting true 14-bit RAW HDR pipeline (adaptive)...")
                    let rawURL = URL(fileURLWithPath: rawPath)

                    DispatchQueue.global(qos: .userInitiated).async {
                        if let hdrPath = self.applyRawHDR(dngURL: rawURL) {
                            self.pendingJpegURL = hdrPath
                            print("✅ HDR+ (14-bit adaptive) done")
                        } else {
                            print("⚠️ HDR+ failed, using original JPEG")
                        }
                        self.completeCallback()
                    }
                } else {
                    print("⚠️ HDR+ requires iOS 15.0+, skipping")
                    completeCallback()
                }
            } else {
                completeCallback()
            }
        }
    }

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
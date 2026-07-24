import AVFoundation
import UIKit
import Flutter
import Photos
import CoreMotion
import CoreImage
import Vision

class CameraManager: NSObject {
    static let shared = CameraManager()

    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private weak var previewLayerForPointConversion: AVCaptureVideoPreviewLayer?
    private var photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoFrameQueue = DispatchQueue(label: "camera.video.frame.queue")
    private let frameProcessingQueue = DispatchQueue(
        label: "camera.frame.processing.queue",
        qos: .userInitiated
    )
    private let videoFrameLock = NSLock()
    private var latestVideoPixelBuffer: CVPixelBuffer?

    private var pendingFrameCaptureID: UUID?
    private var pendingFrameAspectRatio = "16:9"
    private var pendingFrameBuffers: [CVPixelBuffer] = []
    private var pendingFrameCompletion: ((Result<[String: String], Error>) -> Void)?
    private var pendingFrameWaitCount = 0
    private let frameBurstCount = 5
    private var isHDREnabled = false
    private var isRawEnabled = false
    private var isNatural48Enabled = false
    private var isFrameModeEnabled = false
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var lastPhotoCompletion: ((Result<[String: String], Error>) -> Void)?
    private var rawTestDelegate: RawTestCaptureDelegate?
    private var rawBurstControlState: RawBurstControlState?

    private var pendingRawURL: String?
    private var pendingJpegURL: String?
    private var expectedPhotoCount: Int = 1
    private var receivedPhotoCount: Int = 0
    private var captureError: Error?

    private var softwareZoomFactor: CGFloat = 1.0
    private let natural48ZoomFactor: CGFloat = 756.0 / 409.0

    private let motionManager = CMMotionManager()
    private var currentPhysicalOrientation: UIDeviceOrientation = .portrait

    // Core Image context — reusable, Metal GPU-accelerated
    // Configured for wide-gamut Display P3 frame rendering
    private let rawMergeQueue = DispatchQueue(
        label: "camera.raw.merge.queue",
        qos: .userInitiated
    )

    private let ciContext: CIContext = {
        return CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
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

                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                ]
                self.videoOutput.setSampleBufferDelegate(
                    self,
                    queue: self.videoFrameQueue
                )
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
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
                // Keep the live video connection fixed to avoid a pipeline flash.
                // Rotate only the exported frame later in Core Image.
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

    func registerPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayerForPointConversion = layer
    }

    private func devicePointFromPreview(normalizedX: CGFloat, normalizedY: CGFloat) -> CGPoint {
        let convert: () -> CGPoint = {
            guard let layer = self.previewLayerForPointConversion,
                  layer.bounds.width > 0,
                  layer.bounds.height > 0 else {
                return CGPoint(x: normalizedX, y: normalizedY)
            }

            let layerPoint = CGPoint(
                x: normalizedX * layer.bounds.width,
                y: normalizedY * layer.bounds.height
            )
            return layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        }

        if Thread.isMainThread {
            return convert()
        }
        return DispatchQueue.main.sync(execute: convert)
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
        let normalizedX = max(0.0, min(CGFloat(x), 1.0))
        let normalizedY = max(0.0, min(CGFloat(y), 1.0))
        let point = devicePointFromPreview(
            normalizedX: normalizedX,
            normalizedY: normalizedY
        )

        sessionQueue.async {
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported {
                    d.focusPointOfInterest = point
                    if d.isFocusModeSupported(.autoFocus) {
                        // A one-shot scan reacts more decisively to a tap than
                        // merely updating an already-running continuous mode.
                        d.focusMode = .autoFocus
                    } else if d.isFocusModeSupported(.continuousAutoFocus) {
                        d.focusMode = .continuousAutoFocus
                    }
                }
                if d.isExposurePointOfInterestSupported {
                    d.exposurePointOfInterest = point
                }
                if d.isExposureModeSupported(.autoExpose) {
                    d.exposureMode = .autoExpose
                } else if d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposureMode = .continuousAutoExposure
                }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    d.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if d.minExposureTargetBias <= 0 && d.maxExposureTargetBias >= 0 {
                    d.setExposureTargetBias(0, completionHandler: nil)
                }
                d.isSubjectAreaChangeMonitoringEnabled = true
                d.unlockForConfiguration()
                completion(true)

                // After the tap has had time to settle, resume continuous AE/AF.
                // Do not override a manual adjustment made in the meantime.
                self.sessionQueue.asyncAfter(deadline: .now() + 1.0) {
                    do {
                        try d.lockForConfiguration()
                        if d.focusMode == .autoFocus,
                           d.isFocusModeSupported(.continuousAutoFocus) {
                            d.focusMode = .continuousAutoFocus
                        }
                        if d.exposureMode == .autoExpose,
                           d.isExposureModeSupported(.continuousAutoExposure) {
                            d.exposureMode = .continuousAutoExposure
                        }
                        d.unlockForConfiguration()
                    } catch {
                        print("⚠️ Unable to resume continuous AE/AF: \(error)")
                    }
                }
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

    func setFrameMode(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }

        sessionQueue.async {
            self.session.beginConfiguration()
            if enabled && self.session.canSetSessionPreset(.hd4K3840x2160) {
                self.session.sessionPreset = .hd4K3840x2160
            } else {
                self.session.sessionPreset = .photo
            }
            self.session.commitConfiguration()

            if let connection = self.videoOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }

            do {
                try d.lockForConfiguration()
                self.isFrameModeEnabled = enabled
                self.isNatural48Enabled = false
                self.isRawEnabled = false
                self.softwareZoomFactor = 1.0
                d.videoZoomFactor = 1.0
                self.flashMode = .off
                self.isHDREnabled = false

                if enabled {
                    if d.isExposureModeSupported(.continuousAutoExposure) {
                        d.exposureMode = .continuousAutoExposure
                    }
                    if d.isFocusModeSupported(.continuousAutoFocus) {
                        d.focusMode = .continuousAutoFocus
                    }
                    if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        d.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    if d.minExposureTargetBias <= 0 && d.maxExposureTargetBias >= 0 {
                        d.setExposureTargetBias(0, completionHandler: nil)
                    }
                    d.isSubjectAreaChangeMonitoringEnabled = true
                }
                d.unlockForConfiguration()

                if !enabled {
                    self.videoFrameLock.lock()
                    self.latestVideoPixelBuffer = nil
                    self.videoFrameLock.unlock()
                }
                completion(true)
            } catch {
                print("⚠️ 4K Frame mode error: \(error)")
                completion(false)
            }
        }
    }

    func setNatural48Mode(_ enabled: Bool, completion: @escaping (Bool) -> Void) {
        guard let d = device else { completion(false); return }

        sessionQueue.async {
            if self.isFrameModeEnabled {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                self.session.commitConfiguration()
            }

            do {
                try d.lockForConfiguration()

                self.isFrameModeEnabled = false
                self.isNatural48Enabled = enabled
                self.isRawEnabled = false

                if enabled {
                    let zoom = max(
                        1.0,
                        min(self.natural48ZoomFactor, d.activeFormat.videoMaxZoomFactor)
                    )
                    self.softwareZoomFactor = zoom
                    d.videoZoomFactor = zoom

                    if d.isExposureModeSupported(.continuousAutoExposure) {
                        d.exposureMode = .continuousAutoExposure
                    }
                    if d.isFocusModeSupported(.continuousAutoFocus) {
                        d.focusMode = .continuousAutoFocus
                    }
                    if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        d.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    if d.minExposureTargetBias <= 0 && d.maxExposureTargetBias >= 0 {
                        d.setExposureTargetBias(0, completionHandler: nil)
                    }
                    d.isSubjectAreaChangeMonitoringEnabled = true
                    self.flashMode = .off
                    self.isHDREnabled = false
                } else {
                    self.softwareZoomFactor = 1.0
                    d.videoZoomFactor = 1.0
                }

                d.unlockForConfiguration()
                completion(true)
            } catch {
                print("⚠️ 48mm Natural mode error: \(error)")
                completion(false)
            }
        }
    }

    func setRAW(_ enabled: Bool) {
        guard let d = device else { return }

        sessionQueue.async {
            if self.isFrameModeEnabled {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                self.session.commitConfiguration()
            }
            self.isRawEnabled = enabled
            if enabled {
                self.isNatural48Enabled = false
                self.isFrameModeEnabled = false
            }

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

    func getCurrentCameraValues(completion: @escaping ([String: Any]) -> Void) {
        sessionQueue.async {
            guard let d = self.device else {
                DispatchQueue.main.async { completion([:]) }
                return
            }

            let values: [String: Any] = [
                "iso": Double(d.iso),
                "shutterSeconds": CMTimeGetSeconds(d.exposureDuration),
                "focus": Double(d.lensPosition)
            ]
            DispatchQueue.main.async { completion(values) }
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

    var currentSoftwareZoom: CGFloat { softwareZoomFactor }
    var isInRawMode: Bool { isRawEnabled }

    // MARK: - Capture

    func captureVideoFrame(
        aspectRatio: String,
        completion: @escaping (Result<[String: String], Error>) -> Void
    ) {
        videoFrameQueue.async {
            guard self.isFrameModeEnabled else {
                let error = NSError(
                    domain: "Camera",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "4K Frame mode is not enabled"]
                )
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard self.pendingFrameCaptureID == nil else {
                let error = NSError(
                    domain: "Camera",
                    code: 22,
                    userInfo: [NSLocalizedDescriptionKey: "A frame capture is already running"]
                )
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let captureID = UUID()
            self.pendingFrameCaptureID = captureID
            self.pendingFrameAspectRatio = aspectRatio
            self.pendingFrameBuffers.removeAll(keepingCapacity: true)
            self.pendingFrameCompletion = completion
            self.pendingFrameWaitCount = 0

            // Do not leave the shutter waiting forever if the video pipeline stalls.
            self.videoFrameQueue.asyncAfter(deadline: .now() + 2.0) {
                guard self.pendingFrameCaptureID == captureID else { return }

                if let latest = self.latestVideoPixelBuffer {
                    self.pendingFrameBuffers.append(latest)
                    self.finishPendingFrameCapture()
                } else {
                    let timeoutError = NSError(
                        domain: "Camera",
                        code: 23,
                        userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a video frame"]
                    )
                    let callback = self.pendingFrameCompletion
                    self.clearPendingFrameCapture()
                    DispatchQueue.main.async { callback?(.failure(timeoutError)) }
                }
            }
        }
    }

    private func finishPendingFrameCapture() {
        guard pendingFrameCaptureID != nil,
              !pendingFrameBuffers.isEmpty,
              let completion = pendingFrameCompletion else { return }

        let buffers = pendingFrameBuffers
        let aspectRatio = pendingFrameAspectRatio
        clearPendingFrameCapture()

        frameProcessingQueue.async {
            var sharpest = buffers[0]
            var bestScore = self.sharpnessScore(sharpest)
            for buffer in buffers.dropFirst() {
                let score = self.sharpnessScore(buffer)
                if score > bestScore {
                    bestScore = score
                    sharpest = buffer
                }
            }
            self.renderVideoFrame(
                sharpest,
                aspectRatio: aspectRatio,
                completion: completion
            )
        }
    }

    private func clearPendingFrameCapture() {
        pendingFrameCaptureID = nil
        pendingFrameAspectRatio = "16:9"
        pendingFrameBuffers.removeAll(keepingCapacity: true)
        pendingFrameCompletion = nil
        pendingFrameWaitCount = 0
    }

    private func sharpnessScore(_ pixelBuffer: CVPixelBuffer) -> Float {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let longestSide = max(source.extent.width, source.extent.height)
        guard longestSide > 0 else { return 0 }

        let scale = min(1.0, 256.0 / longestSide)
        let smallImage = source.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        guard let edges = CIFilter(
            name: "CIEdges",
            parameters: [
                kCIInputImageKey: smallImage,
                kCIInputIntensityKey: 1.0
            ]
        )?.outputImage,
        let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: edges,
                kCIInputExtentKey: CIVector(cgRect: edges.extent)
            ]
        )?.outputImage else {
            return 0
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        return Float(pixel[0]) + Float(pixel[1]) + Float(pixel[2])
    }

    private func renderVideoFrame(
        _ pixelBuffer: CVPixelBuffer,
        aspectRatio: String,
        completion: @escaping (Result<[String: String], Error>) -> Void
    ) {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let orientation = currentPhysicalOrientation

        // The live video connection stays portrait to prevent preview blinking.
        // Rotate only the selected burst frame for the exported JPEG.
        switch orientation {
        case .portraitUpsideDown:
            image = image.oriented(.down)
        case .landscapeLeft:
            image = image.oriented(.right)
        case .landscapeRight:
            image = image.oriented(.left)
        default:
            break
        }

        let isPortrait = orientation == .portrait || orientation == .portraitUpsideDown

        let desiredLandscapeSize: CGSize
        switch aspectRatio {
        case "4:3":
            desiredLandscapeSize = CGSize(width: 2880, height: 2160)
        case "1:1":
            desiredLandscapeSize = CGSize(width: 2160, height: 2160)
        case "3:2":
            desiredLandscapeSize = CGSize(width: 3240, height: 2160)
        default:
            desiredLandscapeSize = CGSize(width: 3840, height: 2160)
        }

        let desiredOutputSize = isPortrait && aspectRatio != "1:1"
            ? CGSize(
                width: desiredLandscapeSize.height,
                height: desiredLandscapeSize.width
            )
            : desiredLandscapeSize

        let extent = image.extent
        let targetAspect = desiredOutputSize.width / desiredOutputSize.height
        let sourceAspect = extent.width / extent.height
        var cropRect = extent

        if sourceAspect > targetAspect {
            let width = extent.height * targetAspect
            cropRect = CGRect(
                x: extent.midX - width / 2.0,
                y: extent.minY,
                width: width,
                height: extent.height
            )
        } else if sourceAspect < targetAspect {
            let height = extent.width / targetAspect
            cropRect = CGRect(
                x: extent.minX,
                y: extent.midY - height / 2.0,
                width: extent.width,
                height: height
            )
        }

        // Never enlarge a lower-resolution video buffer. This prevents a 1080p
        // source from being mislabeled and softened by upscaling it to 4K.
        let desiredScale = min(
            desiredOutputSize.width / cropRect.width,
            desiredOutputSize.height / cropRect.height
        )
        let renderScale = min(1.0, desiredScale)
        let outputSize = CGSize(
            width: floor(cropRect.width * renderScale),
            height: floor(cropRect.height * renderScale)
        )

        image = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(
                translationX: -cropRect.minX,
                y: -cropRect.minY
            ))
            .transformed(by: CGAffineTransform(
                scaleX: renderScale,
                y: renderScale
            ))

        let outputRect = CGRect(origin: .zero, size: outputSize)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let cgImage = ciContext.createCGImage(
            image,
            from: outputRect,
            format: .RGBA8,
            colorSpace: p3
        ), let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
            let error = NSError(
                domain: "Camera",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Unable to render video frame"]
            )
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "manualcam_\(timestamp)_frame.jpg"
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(filename)

        do {
            try jpegData.write(to: URL(fileURLWithPath: path))
            let result = [
                "jpeg": path,
                "_softwareZoom": String(format: "%.2f", softwareZoomFactor),
                "mode": "sharpFrame",
                "aspectRatio": aspectRatio,
                "width": String(Int(outputSize.width)),
                "height": String(Int(outputSize.height)),
                "burstFrames": String(buffersCountForMetadata)
            ]
            DispatchQueue.main.async { completion(.success(result)) }
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    // Kept as a computed value so capture metadata remains explicit without
    // retaining the complete burst beyond frame selection.
    private var buffersCountForMetadata: Int { frameBurstCount }

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
                if self.isNatural48Enabled {
                    // Keep Apple's native ISP JPEG pipeline and metadata. Setting
                    // videoZoomFactor produces the 48mm-equivalent center crop while
                    // high-resolution capture preserves 4032x3024 output dimensions.
                    settings = AVCapturePhotoSettings(
                        format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                    )
                } else {
                    settings = AVCapturePhotoSettings()
                }
                self.expectedPhotoCount = 1
                settings.isHighResolutionPhotoEnabled = true
                if #available(iOS 13.0, *) {
                    settings.photoQualityPrioritization = self.isNatural48Enabled
                        ? .quality
                        : .balanced
                }
                settings.isAutoStillImageStabilizationEnabled =
                    self.isNatural48Enabled || self.isHDREnabled
            }

            if let d = self.device, d.hasFlash {
                settings.flashMode = self.flashMode
            }

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // Center-crop only the JPEG companion when RAW mode uses software zoom.
    // No HDR, tone mapping, exposure, shadow, or saturation adjustment is applied.
    private func applySoftwareZoom(toJPEGAt path: String) -> String? {
        guard softwareZoomFactor > 1.01 else { return path }

        let sourceURL = URL(fileURLWithPath: path)
        guard var image = CIImage(
            contentsOf: sourceURL,
            options: [.applyOrientationProperty: true]
        ) else {
            print("⚠️ Failed to load JPEG for software zoom")
            return nil
        }

        let cropFactor = 1.0 / softwareZoomFactor
        let extent = image.extent
        let cropWidth = extent.width * cropFactor
        let cropHeight = extent.height * cropFactor
        let cropRect = CGRect(
            x: extent.midX - cropWidth / 2.0,
            y: extent.midY - cropHeight / 2.0,
            width: cropWidth,
            height: cropHeight
        )
        image = image.cropped(to: cropRect)

        guard let cgImage = ciContext.createCGImage(image, from: image.extent),
              let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
            print("⚠️ Failed to render software-zoom JPEG")
            return nil
        }

        let tmpDir = NSTemporaryDirectory()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "manualcam_\(timestamp)_zoom.jpg"
        let outputPath = (tmpDir as NSString).appendingPathComponent(filename)

        do {
            try jpegData.write(to: URL(fileURLWithPath: outputPath))
            print("✅ GPU software zoom applied: \(softwareZoomFactor)x")
            return outputPath
        } catch {
            print("⚠️ Failed to save software-zoom JPEG: \(error)")
            return nil
        }
    }


    // MARK: - RAW Burst Enhanced JPEG Preview

    func mergeRawBurstPreview(
        dngPaths: [String],
        completion: @escaping (Result<[String: String], Error>) -> Void
    ) {
        rawMergeQueue.async {
            do {
                guard dngPaths.count >= 2 else {
                    throw NSError(
                        domain: "Camera",
                        code: 40,
                        userInfo: [NSLocalizedDescriptionKey: "At least two DNG paths are required"]
                    )
                }

                let urls = dngPaths.map { URL(fileURLWithPath: $0) }
                let images = try urls.map { try self.loadRawCIImage(from: $0) }
                let reference = images[0]
                let referenceExtent = reference.extent

                var alignedImages: [CIImage] = [reference]
                var alignmentSummary: [String] = []

                for index in 1..<images.count {
                    let transform = self.estimateTranslationTransform(
                        moving: images[index],
                        reference: reference
                    ) ?? .identity

                    let aligned = images[index]
                        .transformed(by: transform)
                        .cropped(to: referenceExtent)
                    alignedImages.append(aligned)

                    alignmentSummary.append(
                        String(
                            format: "%d:%.2f,%.2f",
                            index + 1,
                            transform.tx,
                            transform.ty
                        )
                    )
                }

                let merged = self.weightedSharpRawBurstMerge(alignedImages)
                    .cropped(to: referenceExtent)

                let outputURL = try self.renderMergedJPEG(
                    merged,
                    extent: referenceExtent
                )

                self.saveJPEGToPhotos(fileURL: outputURL) { result in
                    switch result {
                    case .success:
                        let details: [String: String] = [
                            "enhancedJpeg": outputURL.path,
                            "mergeCount": String(alignedImages.count),
                            "alignment": alignmentSummary.joined(separator: ";")
                        ]
                        completion(.success(details))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func loadRawCIImage(from url: URL) throws -> CIImage {
        let options: [CIImageOption: Any] = [
            .applyOrientationProperty: true
        ]

        if let image = CIImage(contentsOf: url, options: options) {
            return image.transformed(
                by: CGAffineTransform(
                    translationX: -image.extent.origin.x,
                    y: -image.extent.origin.y
                )
            )
        }

        throw NSError(
            domain: "Camera",
            code: 41,
            userInfo: [NSLocalizedDescriptionKey: "Unable to decode RAW DNG: \(url.lastPathComponent)"]
        )
    }

    private func estimateTranslationTransform(
        moving: CIImage,
        reference: CIImage
    ) -> CGAffineTransform? {
        let maxSide: CGFloat = 900.0
        guard let referenceCG = makeRegistrationCGImage(from: reference, maxSide: maxSide),
              let movingCG = makeRegistrationCGImage(from: moving, maxSide: maxSide) else {
            return nil
        }

        do {
            let request = VNTranslationalImageRegistrationRequest(
                targetedCGImage: referenceCG
            )
            let handler = VNImageRequestHandler(cgImage: movingCG, options: [:])
            try handler.perform([request])

            guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
                return nil
            }

            let scale = min(
                maxSide / max(reference.extent.width, reference.extent.height),
                1.0
            )
            var transform = observation.alignmentTransform
            if scale > 0 {
                transform.tx /= scale
                transform.ty /= scale
            }
            return transform
        } catch {
            print("RAW merge alignment failed: \(error)")
            return nil
        }
    }

    private func makeRegistrationCGImage(
        from image: CIImage,
        maxSide: CGFloat
    ) -> CGImage? {
        let extent = image.extent
        let scale = min(maxSide / max(extent.width, extent.height), 1.0)
        let resized = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIPhotoEffectMono")

        return ciContext.createCGImage(resized, from: resized.extent)
    }

    private func weightedSharpRawBurstMerge(_ images: [CIImage]) -> CIImage {
        guard let reference = images.first else {
            return CIImage.empty()
        }

        // Reference-heavy merge for handheld/low-light bursts. Equal averaging
        // lowers noise more, but it also makes 1/15s handheld captures look
        // muddy when there is small residual movement. This keeps frame 1 as
        // the sharp detail anchor while frames 2/3 contribute mild denoising.
        let referenceWeight: CGFloat = 0.70
        let remainingWeight = max(0.0, 1.0 - referenceWeight)
        let extraCount = max(images.count - 1, 1)
        let extraWeight = remainingWeight / CGFloat(extraCount)

        var accumulated = scaleCIImage(reference, by: referenceWeight)

        for image in images.dropFirst() {
            let scaled = scaleCIImage(image, by: extraWeight)
            accumulated = scaled.applyingFilter(
                "CIAdditionCompositing",
                parameters: [kCIInputBackgroundImageKey: accumulated]
            )
        }

        return sharpenMergedPreview(accumulated)
    }

    private func sharpenMergedPreview(_ image: CIImage) -> CIImage {
        // Moderate RAW-preview sharpening. Avoid heavy halos; this is only the
        // enhanced preview while the untouched DNGs remain the primary files.
        let sharpened = image.applyingFilter(
            "CISharpenLuminance",
            parameters: [
                kCIInputSharpnessKey: 0.65
            ]
        )

        return sharpened.applyingFilter(
            "CIUnsharpMask",
            parameters: [
                kCIInputRadiusKey: 1.2,
                kCIInputIntensityKey: 0.35
            ]
        )
    }

    private func scaleCIImage(_ image: CIImage, by value: CGFloat) -> CIImage {
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: value, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: value, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: value, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ]
        )
    }

    private func renderMergedJPEG(_ image: CIImage, extent: CGRect) throws -> URL {
        guard let cgImage = ciContext.createCGImage(image, from: extent) else {
            throw NSError(
                domain: "Camera",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Unable to render merged RAW preview"]
            )
        }

        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.96) else {
            throw NSError(
                domain: "Camera",
                code: 43,
                userInfo: [NSLocalizedDescriptionKey: "Unable to encode merged JPEG"]
            )
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "manualcam_\(timestamp)_raw_burst_merged.jpg"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(filename)
        try jpegData.write(to: url, options: .atomic)
        return url
    }

    private func saveJPEGToPhotos(
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let save: () -> Void = {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: fileURL, options: options)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(error ?? NSError(
                            domain: "Camera",
                            code: 44,
                            userInfo: [NSLocalizedDescriptionKey: "Unable to save merged JPEG to Photos"]
                        )))
                    }
                }
            }
        }

        if #available(iOS 14.0, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    save()
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(NSError(
                            domain: "Camera",
                            code: 45,
                            userInfo: [NSLocalizedDescriptionKey: "Photos add permission was denied"]
                        )))
                    }
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized {
                    save()
                } else {
                    DispatchQueue.main.async {
                        completion(.failure(NSError(
                            domain: "Camera",
                            code: 45,
                            userInfo: [NSLocalizedDescriptionKey: "Photos add permission was denied"]
                        )))
                    }
                }
            }
        }
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }

    // MARK: - Temporary RAW burst controls lock

    private struct RawBurstControlState {
        let exposureMode: AVCaptureDevice.ExposureMode
        let exposureDuration: CMTime
        let iso: Float
        let exposureBias: Float
        let focusMode: AVCaptureDevice.FocusMode
        let lensPosition: Float
        let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
        let whiteBalanceGains: AVCaptureDevice.WhiteBalanceGains
    }

    func beginRawBurstLock(completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            self.waitForRawBurstStability(attempt: 0, completion: completion)
        }
    }

    private func waitForRawBurstStability(
        attempt: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard let d = device else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        let adjusting = d.isAdjustingExposure ||
            d.isAdjustingFocus ||
            d.isAdjustingWhiteBalance
        if adjusting && attempt < 20 {
            sessionQueue.asyncAfter(deadline: .now() + 0.05) {
                self.waitForRawBurstStability(
                    attempt: attempt + 1,
                    completion: completion
                )
            }
            return
        }

        let state = RawBurstControlState(
            exposureMode: d.exposureMode,
            exposureDuration: d.exposureDuration,
            iso: d.iso,
            exposureBias: d.exposureTargetBias,
            focusMode: d.focusMode,
            lensPosition: d.lensPosition,
            whiteBalanceMode: d.whiteBalanceMode,
            whiteBalanceGains: d.deviceWhiteBalanceGains
        )

        do {
            try d.lockForConfiguration()
            if d.isExposureModeSupported(.custom) {
                d.setExposureModeCustom(
                    duration: state.exposureDuration,
                    iso: state.iso,
                    completionHandler: nil
                )
            }
            if d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(
                    lensPosition: state.lensPosition,
                    completionHandler: nil
                )
            }
            if d.isWhiteBalanceModeSupported(.locked) {
                d.setWhiteBalanceModeLocked(
                    with: clampedBurstWhiteBalanceGains(
                        state.whiteBalanceGains,
                        device: d
                    ),
                    completionHandler: nil
                )
            }
            d.unlockForConfiguration()
            rawBurstControlState = state

            sessionQueue.asyncAfter(deadline: .now() + 0.15) {
                DispatchQueue.main.async { completion(true) }
            }
        } catch {
            print("RAW burst lock failed: \(error)")
            DispatchQueue.main.async { completion(false) }
        }
    }

    func endRawBurstLock(completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            guard let d = self.device,
                  let state = self.rawBurstControlState else {
                DispatchQueue.main.async { completion(true) }
                return
            }

            do {
                try d.lockForConfiguration()
                if state.exposureMode == .custom,
                   d.isExposureModeSupported(.custom) {
                    d.setExposureModeCustom(
                        duration: state.exposureDuration,
                        iso: state.iso,
                        completionHandler: nil
                    )
                } else if d.isExposureModeSupported(state.exposureMode) {
                    d.exposureMode = state.exposureMode
                }

                if state.focusMode == .locked,
                   d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLocked(
                        lensPosition: state.lensPosition,
                        completionHandler: nil
                    )
                } else if d.isFocusModeSupported(state.focusMode) {
                    d.focusMode = state.focusMode
                }

                if state.whiteBalanceMode == .locked,
                   d.isWhiteBalanceModeSupported(.locked) {
                    d.setWhiteBalanceModeLocked(
                        with: self.clampedBurstWhiteBalanceGains(
                            state.whiteBalanceGains,
                            device: d
                        ),
                        completionHandler: nil
                    )
                } else if d.isWhiteBalanceModeSupported(state.whiteBalanceMode) {
                    d.whiteBalanceMode = state.whiteBalanceMode
                }

                if d.minExposureTargetBias <= state.exposureBias,
                   state.exposureBias <= d.maxExposureTargetBias {
                    d.setExposureTargetBias(
                        state.exposureBias,
                        completionHandler: nil
                    )
                }
                d.unlockForConfiguration()
                self.rawBurstControlState = nil
                DispatchQueue.main.async { completion(true) }
            } catch {
                print("RAW burst restore failed: \(error)")
                self.rawBurstControlState = nil
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private func clampedBurstWhiteBalanceGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maximum = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: max(1.0, min(gains.redGain, maximum)),
            greenGain: max(1.0, min(gains.greenGain, maximum)),
            blueGain: max(1.0, min(gains.blueGain, maximum))
        )
    }

    // MARK: - Bayer RAW Validation Capture

    func captureRawTest(
        completion: @escaping (Result<[String: String], Error>) -> Void
    ) {
        sessionQueue.async {
            guard self.rawTestDelegate == nil else {
                let error = NSError(
                    domain: "Camera",
                    code: 30,
                    userInfo: [NSLocalizedDescriptionKey: "A RAW test capture is already running"]
                )
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let availableRawFormats = self.photoOutput.availableRawPhotoPixelFormatTypes
            let rawFormat: OSType?
            if #available(iOS 14.3, *) {
                rawFormat = availableRawFormats.first(where: {
                    AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
                })
            } else {
                // Apple ProRAW did not exist before iOS 14.3, so an available
                // RAW format on earlier supported systems is a Bayer RAW format.
                rawFormat = availableRawFormats.first
            }

            guard let rawFormat else {
                let error = NSError(
                    domain: "Camera",
                    code: 31,
                    userInfo: [NSLocalizedDescriptionKey: "Bayer RAW is not available"]
                )
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let orientation = self.videoOrientation(for: self.currentPhysicalOrientation)
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }

            let delegate = RawTestCaptureDelegate(rawFormat: rawFormat) { [weak self] result in
                self?.sessionQueue.async {
                    self?.rawTestDelegate = nil
                }
                DispatchQueue.main.async { completion(result) }
            }
            self.rawTestDelegate = delegate

            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            settings.isHighResolutionPhotoEnabled = false
            settings.isAutoStillImageStabilizationEnabled = false
            if #available(iOS 13.0, *) {
                // RAW capture does not use Apple's fused quality pipeline.
                // Match the known-working standard RAW configuration.
                settings.photoQualityPrioritization = .speed
            }

            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

// MARK: - RawTestCaptureDelegate

final class RawTestCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let requestedRawFormat: OSType
    private let completion: (Result<[String: String], Error>) -> Void
    private var didFinish = false

    init(
        rawFormat: OSType,
        completion: @escaping (Result<[String: String], Error>) -> Void
    ) {
        self.requestedRawFormat = rawFormat
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard !didFinish else { return }
        didFinish = true

        if let error = error {
            completion(.failure(error))
            return
        }

        guard photo.isRawPhoto,
              let dngData = photo.fileDataRepresentation() else {
            completion(.failure(NSError(
                domain: "Camera",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "RAW capture did not produce DNG data"]
            )))
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "manualcam_\(timestamp)_raw_test.dng"
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(filename)

        do {
            try dngData.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            completion(.failure(error))
            return
        }

        var details: [String: String] = [
            "dng": path,
            "rawFormat": Self.fourCC(requestedRawFormat),
            "fileBytes": String(dngData.count)
        ]

        if let pixelBuffer = photo.pixelBuffer {
            details["pixelFormat"] = Self.fourCC(
                CVPixelBufferGetPixelFormatType(pixelBuffer)
            )
            details["width"] = String(CVPixelBufferGetWidth(pixelBuffer))
            details["height"] = String(CVPixelBufferGetHeight(pixelBuffer))
            details["bytesPerRow"] = String(CVPixelBufferGetBytesPerRow(pixelBuffer))
            details["planeCount"] = String(CVPixelBufferGetPlaneCount(pixelBuffer))
        }

        print("✅ RAW TEST: \(details)")
        saveDNGToPhotos(fileURL: URL(fileURLWithPath: path), details: details)
    }

    private func saveDNGToPhotos(
        fileURL: URL,
        details: [String: String]
    ) {
        let save: () -> Void = {
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(
                    with: .photo,
                    fileURL: fileURL,
                    options: options
                )
            }) { success, error in
                if success {
                    self.completion(.success(details))
                } else {
                    self.completion(.failure(error ?? NSError(
                        domain: "Camera",
                        code: 33,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Unable to save DNG to Photos"
                        ]
                    )))
                }
            }
        }

        if #available(iOS 14.0, *) {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                if status == .authorized || status == .limited {
                    save()
                } else {
                    self.completion(.failure(NSError(
                        domain: "Camera",
                        code: 34,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Photos add permission was denied"
                        ]
                    )))
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized {
                    save()
                } else {
                    self.completion(.failure(NSError(
                        domain: "Camera",
                        code: 34,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Photos permission was denied"
                        ]
                    )))
                }
            }
        }
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(value)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isFrameModeEnabled,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        videoFrameLock.lock()
        latestVideoPixelBuffer = pixelBuffer
        videoFrameLock.unlock()

        guard pendingFrameCaptureID != nil else { return }

        let isAdjusting = (device?.isAdjustingFocus ?? false) ||
            (device?.isAdjustingExposure ?? false)
        if isAdjusting && pendingFrameWaitCount < 15 {
            pendingFrameWaitCount += 1
            return
        }

        pendingFrameBuffers.append(pixelBuffer)
        if pendingFrameBuffers.count >= frameBurstCount {
            finishPendingFrameCapture()
        }
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

            // RAW files remain untouched. Only the companion JPEG is cropped
            // when software zoom is active.
            if captureError == nil,
               isRawEnabled,
               softwareZoomFactor > 1.01,
               let jpegPath = pendingJpegURL {
                DispatchQueue.global(qos: .userInitiated).async {
                    if let zoomedPath = self.applySoftwareZoom(toJPEGAt: jpegPath) {
                        self.pendingJpegURL = zoomedPath
                    }
                    self.completeCallback()
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
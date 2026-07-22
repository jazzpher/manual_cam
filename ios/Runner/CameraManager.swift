import AVFoundation
import UIKit
import Flutter
import Photos

class CameraManager: NSObject {
    static let shared = CameraManager()

    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var isHDREnabled = false
    private var isRawEnabled = false
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var lastPhotoCompletion: ((Result<[String: String], Error>) -> Void)?

    private var pendingRawURL: String?
    private var pendingJpegURL: String?
    private var expectedPhotoCount: Int = 1
    private var receivedPhotoCount: Int = 0
    private var captureError: Error?

    private var softwareZoomFactor: CGFloat = 1.0

    // === BRACKET STATE ===
    private var bracketPhotos: [String] = []
    private var bracketExpected: Int = 0
    private var bracketError: Error?
    private var lastBracketCompletion: ((Result<[String], Error>) -> Void)?

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

                let caps = self.getCapabilities()
                DispatchQueue.main.async { completion(.success(caps)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
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
                print("📸 RAW mode zoom: software factor = \(clamped)x")
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

    var currentSoftwareZoom: CGFloat { softwareZoomFactor }
    var isInRawMode: Bool { isRawEnabled }

    // === REGULAR CAPTURE ===
    func capturePhoto(completion: @escaping (Result<[String: String], Error>) -> Void) {
        sessionQueue.async {
            self.pendingRawURL = nil
            self.pendingJpegURL = nil
            self.receivedPhotoCount = 0
            self.captureError = nil
            self.lastPhotoCompletion = completion

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

    // === BRACKET CAPTURE (for HDR+ mode) ===
    // Capture 3 JPEG photos sequentially with -2 EV, 0 EV, +2 EV
    func captureBracket(completion: @escaping (Result<[String], Error>) -> Void) {
        sessionQueue.async {
            self.bracketPhotos = []
            self.bracketExpected = 3
            self.bracketError = nil
            self.lastBracketCompletion = completion

            guard let d = self.device else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "Camera", code: 1, userInfo: [NSLocalizedDescriptionKey: "No device"])))
                }
                return
            }

            // Save original exposure state para ma-restore later
            let originalMode = d.exposureMode
            let originalBias = d.exposureTargetBias

            let biases: [Float] = [-2.0, 0.0, 2.0]

            self.captureBracketSequentially(device: d, biases: biases, index: 0) {
                // Restore original exposure state
                do {
                    try d.lockForConfiguration()
                    d.exposureMode = originalMode
                    if originalMode == .continuousAutoExposure || originalMode == .autoExpose {
                        d.setExposureTargetBias(originalBias, completionHandler: nil)
                    }
                    d.unlockForConfiguration()
                } catch {
                    print("⚠️ Failed to restore exposure: \(error)")
                }

                DispatchQueue.main.async {
                    if let err = self.bracketError {
                        completion(.failure(err))
                    } else {
                        completion(.success(self.bracketPhotos))
                    }
                    self.lastBracketCompletion = nil
                }
            }
        }
    }

    private func captureBracketSequentially(device: AVCaptureDevice, biases: [Float], index: Int, allDone: @escaping () -> Void) {
        if index >= biases.count {
            allDone()
            return
        }

        let targetBias = biases[index]
        print("📸 Bracket \(index + 1)/\(biases.count): EV \(targetBias)")

        // Set exposure bias
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            let clamped = max(device.minExposureTargetBias, min(targetBias, device.maxExposureTargetBias))
            device.setExposureTargetBias(clamped) { [weak self] _ in
                // Wait a bit para stable ang exposure
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.performSingleBracketShot(device: device, biases: biases, index: index, allDone: allDone)
                }
            }
            device.unlockForConfiguration()
        } catch {
            bracketError = error
            allDone()
        }
    }

    private func performSingleBracketShot(device: AVCaptureDevice, biases: [Float], index: Int, allDone: @escaping () -> Void) {
        // Create simple JPEG settings
        let settings = AVCapturePhotoSettings()
        settings.isHighResolutionPhotoEnabled = true
        if #available(iOS 13.0, *) {
            settings.photoQualityPrioritization = .balanced
        }
        settings.isAutoStillImageStabilizationEnabled = false

        if device.hasFlash {
            settings.flashMode = .off // Bracket = no flash
        }

        // Use a temporary delegate para dedicated sa bracket
        let bracketDelegate = BracketPhotoDelegate { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let path):
                self.bracketPhotos.append(path)
                print("✅ Bracket \(index + 1) saved: \(path)")
                self.captureBracketSequentially(device: device, biases: biases, index: index + 1, allDone: allDone)
            case .failure(let error):
                print("❌ Bracket \(index + 1) failed: \(error)")
                self.bracketError = error
                allDone()
            }
        }

        // Retain delegate para hindi ma-dealloc habang capture
        self.currentBracketDelegate = bracketDelegate
        self.photoOutput.capturePhoto(with: settings, delegate: bracketDelegate)
    }

    private var currentBracketDelegate: BracketPhotoDelegate?
}

// Dedicated delegate for bracket shots
class BracketPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let callback: (Result<String, Error>) -> Void

    init(callback: @escaping (Result<String, Error>) -> Void) {
        self.callback = callback
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            callback(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            callback(.failure(NSError(domain: "Camera", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data"])))
            return
        }

        let tmpDir = NSTemporaryDirectory()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "bracket_\(timestamp).jpg"
        let filePath = (tmpDir as NSString).appendingPathComponent(filename)

        do {
            try data.write(to: URL(fileURLWithPath: filePath))
            callback(.success(filePath))
        } catch {
            callback(.failure(error))
        }
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
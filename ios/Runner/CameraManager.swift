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
        let rawFormats = photoOutput.availableRawPhotoPixelFormatTypes.map { "\($0)" }
        print("📸 Available RAW formats: \(rawFormats)")

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
            do {
                try d.lockForConfiguration()
                let clamped = max(1.0, min(factor, d.activeFormat.videoMaxZoomFactor))
                d.videoZoomFactor = clamped
                d.unlockForConfiguration()
                completion(true)
            } catch { completion(false) }
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
    func setRAW(_ enabled: Bool) { isRawEnabled = enabled }

    // === CAPTURE — REWRITTEN with safe RAW support ===
    func capturePhoto(completion: @escaping (Result<[String: String], Error>) -> Void) {
        sessionQueue.async {
            self.pendingRawURL = nil
            self.pendingJpegURL = nil
            self.receivedPhotoCount = 0
            self.captureError = nil
            self.lastPhotoCompletion = completion

            var settings: AVCapturePhotoSettings

            // Attempt RAW+JPEG kung enabled AT supported
            if self.isRawEnabled {
                let rawFormats = self.photoOutput.availableRawPhotoPixelFormatTypes
                if let rawFormat = rawFormats.first {
                    // RAW + processed JPEG combo
                    do {
                        settings = AVCapturePhotoSettings(
                            rawPixelFormatType: rawFormat,
                            processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                        )
                        self.expectedPhotoCount = 2

                        // IMPORTANTE: RAW captures ay hindi supported ang .balanced/.quality prioritization
                        // Dapat .speed lang para hindi mag-crash
                        if #available(iOS 13.0, *) {
                            settings.photoQualityPrioritization = .speed
                        }

                        // RAW ay hindi rin supports high-res photo enabled kasama ng RAW format
                        settings.isHighResolutionPhotoEnabled = false

                        // RAW hindi supports image stabilization
                        settings.isAutoStillImageStabilizationEnabled = false

                        print("📸 RAW+JPEG capture: format=\(rawFormat)")
                    } catch {
                        // Fallback to JPEG-only kung mag-error
                        print("⚠️ RAW settings init failed, falling back to JPEG: \(error)")
                        settings = AVCapturePhotoSettings()
                        self.expectedPhotoCount = 1
                        settings.isHighResolutionPhotoEnabled = true
                        if #available(iOS 13.0, *) {
                            settings.photoQualityPrioritization = .balanced
                        }
                    }
                } else {
                    // No RAW available — fallback JPEG
                    print("⚠️ RAW requested but no RAW format available, JPEG only")
                    settings = AVCapturePhotoSettings()
                    self.expectedPhotoCount = 1
                    settings.isHighResolutionPhotoEnabled = true
                    if #available(iOS 13.0, *) {
                        settings.photoQualityPrioritization = .balanced
                    }
                }
            } else {
                // Normal JPEG-only path
                settings = AVCapturePhotoSettings()
                self.expectedPhotoCount = 1
                settings.isHighResolutionPhotoEnabled = true
                if #available(iOS 13.0, *) {
                    settings.photoQualityPrioritization = .balanced
                }
                settings.isAutoStillImageStabilizationEnabled = self.isHDREnabled
                print("📸 JPEG-only capture")
            }

            if let d = self.device, d.hasFlash {
                settings.flashMode = self.flashMode
            }

            // Wrap capture call sa try/catch via Objective-C exception handler
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            print("❌ photoOutput error: \(error)")
            captureError = error
            checkAndComplete()
            return
        }

        let isRawPhoto = photo.isRawPhoto
        let ext = isRawPhoto ? "dng" : "jpg"

        guard let photoData = photo.fileDataRepresentation() else {
            print("❌ No photo data (isRaw: \(isRawPhoto))")
            captureError = NSError(domain: "Camera", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No photo data"])
            checkAndComplete()
            return
        }

        let tmpDir = NSTemporaryDirectory()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        // Use different filename for RAW vs JPEG para hindi mag-overwrite
        let suffix = isRawPhoto ? "_raw" : ""
        let filename = "manualcam_\(timestamp)\(suffix).\(ext)"
        let filePath = (tmpDir as NSString).appendingPathComponent(filename)

        do {
            try photoData.write(to: URL(fileURLWithPath: filePath))
            if isRawPhoto {
                pendingRawURL = filePath
                print("✅ RAW (DNG) saved: \(filePath) [\(photoData.count) bytes]")
            } else {
                pendingJpegURL = filePath
                print("✅ JPEG saved: \(filePath) [\(photoData.count) bytes]")
            }
        } catch {
            print("❌ Write error: \(error)")
            captureError = error
        }

        checkAndComplete()
    }

    private func checkAndComplete() {
        receivedPhotoCount += 1
        print("📸 Received: \(receivedPhotoCount)/\(expectedPhotoCount)")

        if receivedPhotoCount >= expectedPhotoCount || captureError != nil {
            DispatchQueue.main.async {
                if let error = self.captureError {
                    self.lastPhotoCompletion?(.failure(error))
                } else {
                    var paths: [String: String] = [:]
                    if let jpeg = self.pendingJpegURL { paths["jpeg"] = jpeg }
                    if let raw = self.pendingRawURL { paths["raw"] = raw }
                    self.lastPhotoCompletion?(.success(paths))
                }
                self.lastPhotoCompletion = nil
            }
        }
    }
}
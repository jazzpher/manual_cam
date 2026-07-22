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
                        self.photoOutput.maxPhotoQualityPrioritization = .balanced
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
            } catch {
                completion(false)
            }
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
            } catch {
                completion(false)
            }
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
            } catch {
                completion(false)
            }
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
            } catch {
                completion(false)
            }
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
            } catch {
                completion(false)
            }
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
            } catch {
                completion(false)
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

    func setHDR(_ enabled: Bool) {
        isHDREnabled = enabled
    }

    func setRAW(_ enabled: Bool) {
        isRawEnabled = enabled
    }

    func capturePhoto(completion: @escaping (Result<[String: String], Error>) -> Void) {
        sessionQueue.async {
            self.pendingRawURL = nil
            self.pendingJpegURL = nil
            self.receivedPhotoCount = 0
            self.captureError = nil
            self.lastPhotoCompletion = completion

            let settings: AVCapturePhotoSettings

            if self.isRawEnabled,
               let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                let processedFormat: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.jpeg
                ]
                settings = AVCapturePhotoSettings(
                    rawPixelFormatType: rawFormat,
                    processedFormat: processedFormat
                )
                self.expectedPhotoCount = 2
                print("📸 RAW+JPEG capture")
            } else {
                settings = AVCapturePhotoSettings()
                self.expectedPhotoCount = 1
                print("📸 JPEG-only capture")
            }

            settings.isHighResolutionPhotoEnabled = true

            if #available(iOS 13.0, *) {
                settings.photoQualityPrioritization = .balanced
            }

            settings.isAutoStillImageStabilizationEnabled = self.isRawEnabled || self.isHDREnabled

            if let d = self.device, d.hasFlash {
                settings.flashMode = self.flashMode
            }

            self.photoOutput.capturePhoto(with: settings, delegate: self)
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
        let data = photo.fileDataRepresentation()
        let ext = isRawPhoto ? "dng" : "jpg"

        guard let photoData = data else {
            captureError = NSError(domain: "Camera", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No photo data"])
            checkAndComplete()
            return
        }

        let tmpDir = NSTemporaryDirectory()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let filename = "manualcam_\(timestamp).\(ext)"
        let filePath = (tmpDir as NSString).appendingPathComponent(filename)

        do {
            try photoData.write(to: URL(fileURLWithPath: filePath))
            if isRawPhoto {
                pendingRawURL = filePath
                print("✅ RAW (DNG) saved: \(filePath)")
            } else {
                pendingJpegURL = filePath
                print("✅ JPEG saved: \(filePath)")
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
                    self.lastPhotoCompletion?(.success(paths))
                }
                self.lastPhotoCompletion = nil
            }
        }
    }
}
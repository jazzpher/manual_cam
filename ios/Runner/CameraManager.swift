import AVFoundation
import UIKit
import Flutter
import Photos

/// Native AVFoundation-based camera manager na binibigay ng true manual controls.
class CameraManager: NSObject {
    static let shared = CameraManager()

    let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var isHDREnabled = false
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var lastPhotoCompletion: ((Result<String, Error>) -> Void)?

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

                    // === SPEED OPTIMIZATION ===
                    // Prioritize speed over quality (huge difference sa capture time)
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

    // MARK: - Capture (OPTIMIZED for speed)

    func capturePhoto(completion: @escaping (Result<String, Error>) -> Void) {
        sessionQueue.async {
            let settings = AVCapturePhotoSettings()

            // === SPEED OPTIMIZATIONS ===
            settings.isHighResolutionPhotoEnabled = true

            if #available(iOS 13.0, *) {
                // .balanced ay mas mabilis kaysa .quality
                // .speed ay pinakamabilis pero maliit ang resolution
                settings.photoQualityPrioritization = .balanced
            }

            // Disable auto features na nag-a-add ng delay
            settings.isAutoStillImageStabilizationEnabled = false

            // Flash setting
            if let d = self.device, d.hasFlash {
                settings.flashMode = self.flashMode
            }

            // HDR — sa iOS built into photo output, medyo dagdag delay
            // Kung enabled, wag i-disable stabilization
            if self.isHDREnabled {
                settings.isAutoStillImageStabilizationEnabled = true
            }

            self.lastPhotoCompletion = completion
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

// MARK: - Photo capture delegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.lastPhotoCompletion?(.failure(error))
            }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                self.lastPhotoCompletion?(.failure(NSError(domain: "Camera", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No photo data"])))
            }
            return
        }

        let tmpDir = NSTemporaryDirectory()
        let filename = "manualcam_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let filePath = (tmpDir as NSString).appendingPathComponent(filename)

        do {
            try data.write(to: URL(fileURLWithPath: filePath))
            DispatchQueue.main.async {
                self.lastPhotoCompletion?(.success(filePath))
            }
        } catch {
            DispatchQueue.main.async {
                self.lastPhotoCompletion?(.failure(error))
            }
        }
    }
}

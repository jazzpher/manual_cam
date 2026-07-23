import Flutter
import UIKit
import AVFoundation

class CameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        return CameraPreviewView(frame: frame, viewId: viewId, args: args, messenger: messenger)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

class CameraPreviewView: NSObject, FlutterPlatformView {
    private var _view: UIView
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
        _view = UIView(frame: frame)
        _view.backgroundColor = .black
        super.init()
        setupPreviewLayer()
    }

    func view() -> UIView {
        return _view
    }

    private func setupPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: CameraManager.shared.session)
        // Fill Flutter's selected-ratio viewport. This removes the second set
        // of black bars while preserving proportions (excess edges are cropped).
        layer.videoGravity = .resizeAspectFill
        layer.frame = _view.bounds
        _view.layer.addSublayer(layer)
        previewLayer = layer

        // Update layer frame on layout changes
        _view.layer.masksToBounds = true

        // Observe bounds changes
        DispatchQueue.main.async { [weak self] in
            self?.updateFrame()
        }
    }

    private func updateFrame() {
        previewLayer?.frame = _view.bounds
        // Portrait orientation
        if let connection = previewLayer?.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        // Re-check periodically for bounds changes (Flutter may resize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if self.previewLayer?.frame != self._view.bounds {
                self.updateFrame()
            }
        }
    }
}

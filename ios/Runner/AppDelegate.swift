import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let controller = window?.rootViewController as! FlutterViewController
        let messenger = controller.binaryMessenger

        // Register platform view for native camera preview
        let factory = CameraPreviewFactory(messenger: messenger)
        registrar(forPlugin: "camera_preview")?.register(factory, withId: "native_camera_preview")

        // Register method channel for camera controls
        let channel = FlutterMethodChannel(name: "manual_cam/camera",
                                            binaryMessenger: messenger)
        channel.setMethodCallHandler { (call, result) in
            let mgr = CameraManager.shared
            switch call.method {
            case "setup":
                mgr.setup { r in
                    switch r {
                    case .success(let caps): result(caps)
                    case .failure(let e): result(FlutterError(code: "SETUP_FAIL",
                                                              message: e.localizedDescription,
                                                              details: nil))
                    }
                }
            case "setISO":
                guard let iso = (call.arguments as? [String: Any])?["iso"] as? Double else {
                    result(FlutterError(code: "ARG", message: "iso required", details: nil)); return
                }
                mgr.setISO(Float(iso)) { ok in result(ok) }
            case "setShutterSpeed":
                guard let sec = (call.arguments as? [String: Any])?["seconds"] as? Double else {
                    result(FlutterError(code: "ARG", message: "seconds required", details: nil)); return
                }
                mgr.setShutterSpeed(sec) { ok in result(ok) }
            case "setExposureBias":
                guard let bias = (call.arguments as? [String: Any])?["bias"] as? Double else {
                    result(FlutterError(code: "ARG", message: "bias required", details: nil)); return
                }
                mgr.setExposureBias(Float(bias)) { ok in result(ok) }
            case "setFocus":
                guard let pos = (call.arguments as? [String: Any])?["position"] as? Double else {
                    result(FlutterError(code: "ARG", message: "position required", details: nil)); return
                }
                mgr.setFocus(Float(pos)) { ok in result(ok) }
            case "focusAtPoint":
                let args = call.arguments as? [String: Any] ?? [:]
                let x = args["x"] as? Double ?? 0.5
                let y = args["y"] as? Double ?? 0.5
                mgr.focusAtPoint(x: Float(x), y: Float(y)) { ok in result(ok) }
            case "setZoom":
                guard let z = (call.arguments as? [String: Any])?["factor"] as? Double else {
                    result(FlutterError(code: "ARG", message: "factor required", details: nil)); return
                }
                mgr.setZoom(CGFloat(z)) { ok in result(ok) }
            case "setFlashMode":
                let mode = (call.arguments as? [String: Any])?["mode"] as? String ?? "off"
                mgr.setFlashMode(mode)
                result(true)
            case "setHDR":
                let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                mgr.setHDR(enabled)
                result(true)
            case "capturePhoto":
                mgr.capturePhoto { r in
                    switch r {
                    case .success(let path): result(path)
                    case .failure(let e): result(FlutterError(code: "CAPTURE_FAIL",
                                                              message: e.localizedDescription,
                                                              details: nil))
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

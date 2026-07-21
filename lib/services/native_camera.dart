import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';

/// Bridge sa native iOS AVFoundation camera.
/// Naga-access ng TRUE manual controls (ISO, shutter, focus, HDR).
class NativeCamera {
  static const _channel = MethodChannel('manual_cam/camera');

  bool _initialized = false;
  Map<String, dynamic> _capabilities = {};

  bool get isInitialized => _initialized;
  Map<String, dynamic> get capabilities => _capabilities;

  double get minISO => (_capabilities['minISO'] as num?)?.toDouble() ?? 24.0;
  double get maxISO => (_capabilities['maxISO'] as num?)?.toDouble() ?? 3200.0;
  double get minShutter => (_capabilities['minExposureDuration'] as num?)?.toDouble() ?? (1 / 8000);
  double get maxShutter => (_capabilities['maxExposureDuration'] as num?)?.toDouble() ?? 1.0;
  double get maxZoom => (_capabilities['maxZoom'] as num?)?.toDouble() ?? 10.0;
  bool get supportsHDR => _capabilities['supportsHDR'] as bool? ?? false;

  Future<void> initialize() async {
    if (_initialized) return;

    // Request camera permission via Dart side
    final camStatus = await Permission.camera.request();
    if (!camStatus.isGranted) {
      throw Exception('Camera permission denied');
    }

    try {
      final Map<Object?, Object?>? result = await _channel.invokeMethod('setup');
      if (result == null) throw Exception('Setup returned null');
      _capabilities = result.map((k, v) => MapEntry(k.toString(), v));
      _initialized = true;
      print('✅ Native camera setup complete: $_capabilities');
    } on PlatformException catch (e) {
      throw Exception('Native camera setup failed: ${e.message}');
    }
  }

  Future<void> setISO(double iso) async {
    try {
      await _channel.invokeMethod('setISO', {'iso': iso});
    } catch (e) {
      print('setISO error: $e');
    }
  }

  Future<void> setShutterSpeed(double seconds) async {
    try {
      await _channel.invokeMethod('setShutterSpeed', {'seconds': seconds});
    } catch (e) {
      print('setShutterSpeed error: $e');
    }
  }

  Future<void> setExposureBias(double bias) async {
    try {
      await _channel.invokeMethod('setExposureBias', {'bias': bias});
    } catch (e) {
      print('setExposureBias error: $e');
    }
  }

  Future<void> setFocus(double position) async {
    try {
      await _channel.invokeMethod('setFocus', {'position': position});
    } catch (e) {
      print('setFocus error: $e');
    }
  }

  Future<void> focusAtPoint(double x, double y) async {
    try {
      await _channel.invokeMethod('focusAtPoint', {'x': x, 'y': y});
    } catch (e) {
      print('focusAtPoint error: $e');
    }
  }

  Future<void> setZoom(double factor) async {
    try {
      await _channel.invokeMethod('setZoom', {'factor': factor});
    } catch (e) {
      print('setZoom error: $e');
    }
  }

  Future<void> setFlashMode(String mode) async {
    try {
      await _channel.invokeMethod('setFlashMode', {'mode': mode});
    } catch (e) {
      print('setFlashMode error: $e');
    }
  }

  Future<void> setHDR(bool enabled) async {
    try {
      await _channel.invokeMethod('setHDR', {'enabled': enabled});
    } catch (e) {
      print('setHDR error: $e');
    }
  }

  /// Capture at save sa Photos app. Returns file path.
  Future<String> capturePhoto() async {
    try {
      final String? path = await _channel.invokeMethod<String>('capturePhoto');
      if (path == null) throw Exception('Capture returned null');

      // Save to Photos app
      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) {
          await Gal.requestAccess(toAlbum: true);
        }
        await Gal.putImage(path, album: 'ManualCam');
        print('✅ Saved to Photos app: $path');
      } catch (e) {
        print('❌ Photos save error: $e');
      }

      return path;
    } on PlatformException catch (e) {
      throw Exception('Capture failed: ${e.message}');
    }
  }
}

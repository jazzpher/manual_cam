import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';

/// Bridge sa native iOS AVFoundation camera.
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
  bool get supportsRAW => _capabilities['supportsRAW'] as bool? ?? false;

  Future<void> initialize() async {
    if (_initialized) return;

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

  Future<void> setRAW(bool enabled) async {
    try {
      await _channel.invokeMethod('setRAW', {'enabled': enabled});
    } catch (e) {
      print('setRAW error: $e');
    }
  }

  /// Capture at save sa Photos app.
  /// Returns map: {'jpeg': path, 'raw': path (optional)}
  Future<Map<String, String>> capturePhoto() async {
    try {
      final result = await _channel.invokeMethod('capturePhoto');
      if (result == null) throw Exception('Capture returned null');

      final Map<String, String> paths = {};
      if (result is Map) {
        result.forEach((k, v) {
          if (k is String && v is String) {
            paths[k] = v;
          }
        });
      }

      if (paths.isEmpty) throw Exception('No files created');

      // Save each file to Photos app
      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) {
          await Gal.requestAccess(toAlbum: true);
        }

        // Save JPEG (viewable sa Photos)
        if (paths['jpeg'] != null) {
          await Gal.putImage(paths['jpeg']!, album: 'ManualCam');
          print('✅ JPEG saved to Photos: ${paths['jpeg']}');
        }

        // Save DNG/RAW (Photos supports DNG since iOS 10)
        if (paths['raw'] != null) {
          await Gal.putImage(paths['raw']!, album: 'ManualCam');
          print('✅ RAW/DNG saved to Photos: ${paths['raw']}');
        }
      } catch (e) {
        print('❌ Photos save error: $e');
      }

      return paths;
    } on PlatformException catch (e) {
      throw Exception('Capture failed: ${e.message}');
    }
  }
}
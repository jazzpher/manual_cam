import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';

/// Native iOS AVFoundation bridge with GPU-based RAW companion JPEG zoom.
class NativeCamera {
  static const _channel = MethodChannel('manual_cam/camera');

  bool _initialized = false;
  Map<String, dynamic> _capabilities = {};

  bool get isInitialized => _initialized;
  Map<String, dynamic> get capabilities => _capabilities;

  double get minISO => (_capabilities['minISO'] as num?)?.toDouble() ?? 24.0;
  double get maxISO => (_capabilities['maxISO'] as num?)?.toDouble() ?? 3200.0;
  double get minShutter =>
      (_capabilities['minExposureDuration'] as num?)?.toDouble() ?? (1 / 8000);
  double get maxShutter =>
      (_capabilities['maxExposureDuration'] as num?)?.toDouble() ?? 1.0;
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
      final Map<Object?, Object?>? result = await _channel.invokeMethod(
        'setup',
      );
      if (result == null) throw Exception('Setup returned null');
      _capabilities = result.map((k, v) => MapEntry(k.toString(), v));
      _initialized = true;
      print('✅ Native camera setup complete');
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

  Future<bool> setFrameMode(bool enabled) async {
    try {
      final result = await _channel.invokeMethod('setFrameMode', {
        'enabled': enabled,
      });
      return result == true;
    } catch (e) {
      print('setFrameMode error: $e');
      return false;
    }
  }

  Future<bool> setNatural48Mode(bool enabled) async {
    try {
      final result = await _channel.invokeMethod('setNatural48Mode', {
        'enabled': enabled,
      });
      return result == true;
    } catch (e) {
      print('setNatural48Mode error: $e');
      return false;
    }
  }

  Future<Map<String, double>> getCurrentCameraValues() async {
    try {
      final result = await _channel.invokeMethod('getCurrentCameraValues');
      if (result is! Map) return {};

      final values = <String, double>{};
      result.forEach((key, value) {
        if (key is String && value is num) {
          values[key] = value.toDouble();
        }
      });
      return values;
    } catch (e) {
      print('getCurrentCameraValues error: $e');
      return {};
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

  Future<int> getCurrentOrientationCode() async {
    try {
      final result = await _channel.invokeMethod('getOrientation');
      return (result as int?) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Regular capture. The DNG/RAW stays untouched for editing.
  /// A RAW companion JPEG may be center-cropped on the native GPU for zoom.
  Future<Map<String, String>> capturePhoto() => _captureAndSave('capturePhoto');

  Future<Map<String, String>> captureVideoFrame(String aspectRatio) =>
      _captureAndSave(
        'captureVideoFrame',
        arguments: {'aspectRatio': aspectRatio},
      );

  Future<Map<String, String>> _captureAndSave(
    String method, {
    Map<String, dynamic>? arguments,
  }) async {
    try {
      final result = await _channel.invokeMethod(method, arguments);
      if (result == null) throw Exception('Capture returned null');

      final Map<String, String> paths = {};
      double softwareZoom = 1.0;

      if (result is Map) {
        result.forEach((k, v) {
          if (k is String && v is String) {
            if (k == '_softwareZoom') {
              softwareZoom = double.tryParse(v) ?? 1.0;
            } else {
              paths[k] = v;
            }
          }
        });
      }

      if (paths.isEmpty) throw Exception('No files created');

      // Save to Photos app
      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) await Gal.requestAccess(toAlbum: true);

        if (paths['jpeg'] != null) {
          await Gal.putImage(paths['jpeg']!, album: 'ManualCam');
        }
        if (paths['raw'] != null) {
          await Gal.putImage(paths['raw']!, album: 'ManualCam');
        }
      } catch (e) {
        print('❌ Photos save error: $e');
      }

      paths['zoom'] = softwareZoom.toStringAsFixed(1);
      return paths;
    } on PlatformException catch (e) {
      throw Exception('$method failed: ${e.message}');
    }
  }

  /// Diagnostic capture of one standard Bayer RAW frame as an untouched DNG.
  Future<Map<String, String>> captureRawTest() async {
    try {
      final result = await _channel.invokeMethod('captureRawTest');
      if (result == null) throw Exception('RAW test capture returned null');

      final Map<String, String> paths = {};
      if (result is Map) {
        result.forEach((k, v) {
          if (k is String && v is String) {
            paths[k] = v;
          }
        });
      }

      if (paths.isEmpty) throw Exception('No files created');

      // The DNG is saved natively using PhotoKit. Gal is intentionally not
      // used here because generic image writers may not safely handle DNG files.
      return paths;
    } on PlatformException catch (e) {
      throw Exception('RAW test capture failed: ${e.message}');
    }
  }
}

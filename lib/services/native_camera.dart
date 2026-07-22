import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';

/// Bridge sa native iOS AVFoundation camera.
/// HDR+ processing at software zoom crop ay ginagawa sa Swift side (Metal GPU).
class NativeCamera {
  static const _channel = MethodChannel('manual_cam/camera');

  bool _initialized = false;
  Map<String, dynamic> _capabilities = {};

  // HDR+ mode state — pinapasa sa native side via method channel
  bool _hdrMode = false;

  bool get isInitialized => _initialized;
  Map<String, dynamic> get capabilities => _capabilities;

  double get minISO => (_capabilities['minISO'] as num?)?.toDouble() ?? 24.0;
  double get maxISO => (_capabilities['maxISO'] as num?)?.toDouble() ?? 3200.0;
  double get minShutter => (_capabilities['minExposureDuration'] as num?)?.toDouble() ?? (1 / 8000);
  double get maxShutter => (_capabilities['maxExposureDuration'] as num?)?.toDouble() ?? 1.0;
  double get maxZoom => (_capabilities['maxZoom'] as num?)?.toDouble() ?? 10.0;
  bool get supportsHDR => _capabilities['supportsHDR'] as bool? ?? false;
  bool get supportsRAW => _capabilities['supportsRAW'] as bool? ?? false;

  /// HDR+ setter — auto-enables RAW mode kasi kailangan ng DNG
  /// para sa true 14-bit CIRAWFilter processing sa Swift side.
  bool get hdrMode => _hdrMode;
  set hdrMode(bool enabled) {
    _hdrMode = enabled;
    _channel.invokeMethod('setHdrPlus', {'enabled': enabled}).catchError((e) {
      print('setHdrPlus error: $e');
    });
    // Auto-enable RAW kapag HDR+ is ON — walang DNG = walang 14-bit HDR
    if (enabled && supportsRAW) {
      _channel.invokeMethod('setRAW', {'enabled': true}).catchError((e) {
        print('auto-enable RAW error: $e');
      });
    }
  }

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
      print('✅ Native camera setup complete');
    } on PlatformException catch (e) {
      throw Exception('Native camera setup failed: ${e.message}');
    }
  }

  Future<void> setISO(double iso) async {
    try { await _channel.invokeMethod('setISO', {'iso': iso}); }
    catch (e) { print('setISO error: $e'); }
  }

  Future<void> setShutterSpeed(double seconds) async {
    try { await _channel.invokeMethod('setShutterSpeed', {'seconds': seconds}); }
    catch (e) { print('setShutterSpeed error: $e'); }
  }

  Future<void> setExposureBias(double bias) async {
    try { await _channel.invokeMethod('setExposureBias', {'bias': bias}); }
    catch (e) { print('setExposureBias error: $e'); }
  }

  Future<void> setFocus(double position) async {
    try { await _channel.invokeMethod('setFocus', {'position': position}); }
    catch (e) { print('setFocus error: $e'); }
  }

  Future<void> focusAtPoint(double x, double y) async {
    try { await _channel.invokeMethod('focusAtPoint', {'x': x, 'y': y}); }
    catch (e) { print('focusAtPoint error: $e'); }
  }

  Future<void> setZoom(double factor) async {
    try { await _channel.invokeMethod('setZoom', {'factor': factor}); }
    catch (e) { print('setZoom error: $e'); }
  }

  Future<void> setFlashMode(String mode) async {
    try { await _channel.invokeMethod('setFlashMode', {'mode': mode}); }
    catch (e) { print('setFlashMode error: $e'); }
  }

  Future<void> setHDR(bool enabled) async {
    try { await _channel.invokeMethod('setHDR', {'enabled': enabled}); }
    catch (e) { print('setHDR error: $e'); }
  }

  Future<void> setRAW(bool enabled) async {
    // Prevent disabling RAW kapag HDR+ ay ON
    if (!enabled && _hdrMode) {
      print('⚠️ Cannot disable RAW while HDR+ is ON (RAW is required for 14-bit HDR)');
      return;
    }
    try { await _channel.invokeMethod('setRAW', {'enabled': enabled}); }
    catch (e) { print('setRAW error: $e'); }
  }

  Future<int> getCurrentOrientationCode() async {
    try {
      final result = await _channel.invokeMethod('getOrientation');
      return (result as int?) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Regular capture. HDR+ processing AT software zoom crop ay handled na sa Swift side.
  /// Yung DNG/RAW ay untouched (para sa Lightroom editing).
  Future<Map<String, String>> capturePhoto() async {
    try {
      final result = await _channel.invokeMethod('capturePhoto');
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

      // NOTE: Software zoom crop AT HDR+ processing ay ginagawa na sa Swift side.
      // Yung JPEG na binalik sa amin ay pre-processed na (kung applicable).

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
      } catch (e) { print('❌ Photos save error: $e'); }

      paths['zoom'] = softwareZoom.toStringAsFixed(1);
      return paths;
    } on PlatformException catch (e) {
      throw Exception('Capture failed: ${e.message}');
    }
  }
}
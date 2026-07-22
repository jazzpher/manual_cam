import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;

/// Bridge sa native iOS AVFoundation camera.
class NativeCamera {
  static const _channel = MethodChannel('manual_cam/camera');

  bool _initialized = false;
  Map<String, dynamic> _capabilities = {};

  // === CINEMATIC MODE STATE ===
  bool cinematicMode = false;
  bool letterboxEnabled = true;

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
    try { await _channel.invokeMethod('setRAW', {'enabled': enabled}); }
    catch (e) { print('setRAW error: $e'); }
  }

  /// Get physical device orientation from native (via CoreMotion).
  /// Returns: 0=portrait, 1=landscapeRight, 2=upsideDown, 3=landscapeLeft
  Future<int> getCurrentOrientationCode() async {
    try {
      final result = await _channel.invokeMethod('getOrientation');
      return (result as int?) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Regular capture. Auto-applies cinematic grade sa JPEG kapag `cinematicMode` ON.
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

      // Software zoom crop for RAW mode
      if (softwareZoom > 1.01 && paths['raw'] != null && paths['jpeg'] != null) {
        try {
          final croppedJpegPath = await _softwareZoomCrop(paths['jpeg']!, softwareZoom);
          if (croppedJpegPath != null) paths['jpeg'] = croppedJpegPath;
        } catch (e) { print('⚠️ JPEG crop failed: $e'); }
      }

      // === CINEMATIC GRADE ===
      if (cinematicMode && paths['jpeg'] != null) {
        try {
          print('🎬 Applying cinematic grade...');
          final gradedPath = await _applyCinematicGrade(
            paths['jpeg']!,
            letterbox: letterboxEnabled,
          );
          if (gradedPath != null) {
            paths['jpeg'] = gradedPath;
            print('✅ Cinematic grade applied');
          }
        } catch (e) { print('⚠️ Cinematic grade failed: $e'); }
      }

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

  /// Applies 5-layer cinematic grade: teal-orange, S-curve, rolloff, vignette, letterbox.
  Future<String?> _applyCinematicGrade(String jpegPath, {bool letterbox = true}) async {
    try {
      final file = File(jpegPath);
      final bytes = await file.readAsBytes();
      var image = img.decodeJpg(bytes);
      if (image == null) return null;

      final w = image.width;
      final h = image.height;
      final cx = w / 2.0;
      final cy = h / 2.0;
      final maxDistSq = (cx * cx + cy * cy);

      // Pre-compute S-curve lookup table
      final sCurve = List<int>.generate(256, (v) {
        final normalized = v / 255.0;
        final curved = 1.0 / (1.0 + math.exp(-6.0 * (normalized - 0.5)));
        return (curved * 255.0).round().clamp(0, 255);
      });

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final pixel = image.getPixel(x, y);
          double r = pixel.r.toDouble();
          double g = pixel.g.toDouble();
          double b = pixel.b.toDouble();

          // 1. Teal-orange grade based on luminance
          final lum = 0.299 * r + 0.587 * g + 0.114 * b;
          final normLum = lum / 255.0;
          final shadowW = 1.0 - normLum;
          final highlightW = normLum;

          r += -8.0 * shadowW + 10.0 * highlightW;
          g += 4.0 * shadowW + 4.0 * highlightW;
          b += 12.0 * shadowW - 8.0 * highlightW;

          // 2. S-curve contrast
          r = sCurve[r.round().clamp(0, 255)].toDouble();
          g = sCurve[g.round().clamp(0, 255)].toDouble();
          b = sCurve[b.round().clamp(0, 255)].toDouble();

          // 3. Highlight rolloff
          if (r > 230) r = 230 + (r - 230) * 0.5;
          if (g > 230) g = 230 + (g - 230) * 0.5;
          if (b > 230) b = 230 + (b - 230) * 0.5;

          // 4. Vignette
          final dx = x - cx;
          final dy = y - cy;
          final distSq = dx * dx + dy * dy;
          final vignette = 1.0 - (distSq / maxDistSq) * 0.35;
          r *= vignette;
          g *= vignette;
          b *= vignette;

          image.setPixelRgb(
            x, y,
            r.round().clamp(0, 255),
            g.round().clamp(0, 255),
            b.round().clamp(0, 255),
          );
        }
      }

      // 5. Letterbox — 2.35:1 cinemascope bars
      if (letterbox) {
        final currentAspect = w / h;
        const targetAspect = 2.35;

        if (currentAspect < targetAspect) {
          final targetH = (w / targetAspect).round();
          final barH = ((h - targetH) / 2).round();

          for (int y = 0; y < barH; y++) {
            for (int x = 0; x < w; x++) {
              image.setPixelRgb(x, y, 0, 0, 0);
            }
          }
          for (int y = h - barH; y < h; y++) {
            for (int x = 0; x < w; x++) {
              image.setPixelRgb(x, y, 0, 0, 0);
            }
          }
        }
      }

      final jpg = img.encodeJpg(image, quality: 92);
      final newPath = jpegPath.replaceFirst('.jpg', '_cine.jpg');
      await File(newPath).writeAsBytes(jpg);
      return newPath;
    } catch (e) {
      print('Cinematic grade error: $e');
      return null;
    }
  }

  Future<String?> _softwareZoomCrop(String jpegPath, double zoomFactor) async {
    if (zoomFactor <= 1.01) return jpegPath;
    try {
      final file = File(jpegPath);
      final bytes = await file.readAsBytes();
      final decoded = img.decodeJpg(bytes);
      if (decoded == null) return null;

      final cropFactor = 1.0 / zoomFactor;
      final newW = (decoded.width * cropFactor).round();
      final newH = (decoded.height * cropFactor).round();
      final offsetX = ((decoded.width - newW) / 2).round();
      final offsetY = ((decoded.height - newH) / 2).round();

      final cropped = img.copyCrop(decoded, x: offsetX, y: offsetY, width: newW, height: newH);
      final croppedBytes = img.encodeJpg(cropped, quality: 92);
      final newPath = jpegPath.replaceFirst('.jpg', '_zoom.jpg');
      await File(newPath).writeAsBytes(croppedBytes);
      return newPath;
    } catch (e) {
      print('Software crop error: $e');
      return null;
    }
  }
}
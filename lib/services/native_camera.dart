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

  // === HDR MODE STATE ===
  // Kapag ON, magcacapture ng RAW+JPEG tapos gagawa ng
  // 3 virtual exposures mula sa JPEG (via digital brightening/darkening)
  // tapos i-blend as single HDR JPEG.
  bool hdrMode = false;

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
  Future<int> getCurrentOrientationCode() async {
    try {
      final result = await _channel.invokeMethod('getOrientation');
      return (result as int?) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  /// Regular capture. Auto-applies HDR mode kapag `hdrMode` ON.
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

      // === HDR MODE: Single-shot digital exposure bracketing ===
      if (hdrMode && paths['jpeg'] != null) {
        try {
          print('🌈 Applying single-shot HDR (digital bracketing)...');
          final hdrPath = await _applyDigitalHDR(paths['jpeg']!);
          if (hdrPath != null) {
            paths['jpeg'] = hdrPath;
            print('✅ HDR applied');
          }
        } catch (e) { print('⚠️ HDR failed: $e'); }
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

  /// === SINGLE-SHOT DIGITAL HDR ===
  /// Gumagawa ng 3 virtual exposures mula sa iisang JPEG:
  ///   - Underexposed (-2 EV): tone-mapped to recover highlights
  ///   - Normal (0 EV): baseline
  ///   - Overexposed (+2 EV): tone-mapped to lift shadows
  /// Tapos i-blend gamit ang luminance-weighted masking:
  ///   - Bright pixels → use underexposed version
  ///   - Dark pixels → use overexposed version
  ///   - Mid pixels → mostly normal
  ///
  /// Advantage: hindi kailangan ng multiple shots, walang ghosting/blur risk,
  /// handhold-friendly.
  Future<String?> _applyDigitalHDR(String jpegPath) async {
    try {
      final file = File(jpegPath);
      final bytes = await file.readAsBytes();
      final image = img.decodeJpg(bytes);
      if (image == null) return null;

      final w = image.width;
      final h = image.height;

      // === Pre-compute exposure lookup tables (LUTs) ===
      // Under: darker (0.5x brightness) with gamma to preserve highlights detail
      final underLUT = List<int>.generate(256, (v) {
        final n = v / 255.0;
        // Reduce by ~2 EV = 4x darker sa linear (but nonlinear para may detail sa highlights)
        final darkened = math.pow(n, 2.0).toDouble() * 255.0;
        return darkened.round().clamp(0, 255);
      });

      // Over: brighter (2x) with inverse gamma to preserve shadow detail
      final overLUT = List<int>.generate(256, (v) {
        final n = v / 255.0;
        // Boost by ~2 EV = 4x brighter sa linear, tapos compress na hindi mag-blowout
        final brightened = math.pow(n, 0.5).toDouble() * 255.0;
        return brightened.round().clamp(0, 255);
      });

      // === Blend using luminance-weighted masking ===
      // Ito ang core ng "HDR merge":
      //   - Bright areas (>200): use UNDER (para may detail yung sky, atbp.)
      //   - Dark areas (<55): use OVER (para makita yung shadows)
      //   - Midtones (55-200): mostly NORMAL

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final pixel = image.getPixel(x, y);
          final r = pixel.r.toInt().clamp(0, 255);
          final g = pixel.g.toInt().clamp(0, 255);
          final b = pixel.b.toInt().clamp(0, 255);

          // Virtual exposures
          final ur = underLUT[r], ug = underLUT[g], ub = underLUT[b];
          final or_ = overLUT[r], og = overLUT[g], ob = overLUT[b];
          // Normal = r, g, b as-is

          // Luminance of original (for masking weights)
          final lum = 0.299 * r + 0.587 * g + 0.114 * b;

          double wUnder, wNormal, wOver;

          if (lum > 200) {
            // Very bright — favor UNDER (recover highlights)
            final t = ((lum - 200) / 55).clamp(0.0, 1.0);
            wUnder = 0.5 + 0.4 * t;
            wNormal = 0.4 - 0.3 * t;
            wOver = 0.1 - 0.1 * t;
          } else if (lum > 140) {
            // Highlights — mix under+normal
            final t = ((lum - 140) / 60).clamp(0.0, 1.0);
            wUnder = 0.2 + 0.3 * t;
            wNormal = 0.7 - 0.2 * t;
            wOver = 0.1 - 0.1 * t;
          } else if (lum < 55) {
            // Very dark — favor OVER (lift shadows)
            final t = ((55 - lum) / 55).clamp(0.0, 1.0);
            wOver = 0.5 + 0.4 * t;
            wNormal = 0.4 - 0.3 * t;
            wUnder = 0.1 - 0.1 * t;
          } else if (lum < 115) {
            // Shadows — mix normal+over
            final t = ((115 - lum) / 60).clamp(0.0, 1.0);
            wOver = 0.2 + 0.3 * t;
            wNormal = 0.7 - 0.2 * t;
            wUnder = 0.1 - 0.1 * t;
          } else {
            // Midtones — mostly normal
            wUnder = 0.15;
            wNormal = 0.7;
            wOver = 0.15;
          }

          // Normalize weights
          wUnder = wUnder.clamp(0.0, 1.0);
          wNormal = wNormal.clamp(0.0, 1.0);
          wOver = wOver.clamp(0.0, 1.0);
          final total = wUnder + wNormal + wOver;
          wUnder /= total;
          wNormal /= total;
          wOver /= total;

          // Blend
          final finalR = (ur * wUnder + r * wNormal + or_ * wOver).round().clamp(0, 255);
          final finalG = (ug * wUnder + g * wNormal + og * wOver).round().clamp(0, 255);
          final finalB = (ub * wUnder + b * wNormal + ob * wOver).round().clamp(0, 255);

          image.setPixelRgb(x, y, finalR, finalG, finalB);
        }
      }

      // Konting contrast + saturation boost para pop
      final adjusted = img.adjustColor(image, contrast: 1.05, saturation: 1.08);

      final jpg = img.encodeJpg(adjusted, quality: 92);
      final newPath = jpegPath.replaceFirst('.jpg', '_hdr.jpg');
      await File(newPath).writeAsBytes(jpg);
      return newPath;
    } catch (e) {
      print('HDR error: $e');
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
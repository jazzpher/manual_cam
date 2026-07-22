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

  Future<int> getCurrentOrientationCode() async {
    try {
      final result = await _channel.invokeMethod('getOrientation');
      return (result as int?) ?? 0;
    } catch (e) {
      return 0;
    }
  }

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

      if (softwareZoom > 1.01 && paths['raw'] != null && paths['jpeg'] != null) {
        try {
          final croppedJpegPath = await _softwareZoomCrop(paths['jpeg']!, softwareZoom);
          if (croppedJpegPath != null) paths['jpeg'] = croppedJpegPath;
        } catch (e) { print('⚠️ JPEG crop failed: $e'); }
      }

      if (hdrMode && paths['jpeg'] != null) {
        try {
          print('🌈 Applying luminance-only HDR (color-preserving)...');
          final hdrPath = await _applyLuminanceHDR(paths['jpeg']!);
          if (hdrPath != null) {
            paths['jpeg'] = hdrPath;
            print('✅ HDR applied (colors preserved)');
          }
        } catch (e) { print('⚠️ HDR failed: $e'); }
      }

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

  /// === LUMINANCE-ONLY HDR ===
  /// Process only the luminance channel (Y in YCbCr) para hindi mag-alter yung colors.
  /// Yung original hue at saturation ay maintained perfectly.
  ///
  /// Process:
  /// 1. Convert RGB → YCbCr (Y=brightness, Cb=blue-diff, Cr=red-diff)
  /// 2. Create 3 virtual Y-channel exposures (under, normal, over)
  /// 3. Blend Y using luminance-weighted masking
  /// 4. Convert back YCbCr → RGB using NEW Y + ORIGINAL Cb/Cr
  ///
  /// Result: brightness ay ma-e-enhance sa dark/bright areas,
  /// pero yung colors (skin tone, sky blue, atbp.) ay hindi magbabago.
  Future<String?> _applyLuminanceHDR(String jpegPath) async {
    try {
      final file = File(jpegPath);
      final bytes = await file.readAsBytes();
      final image = img.decodeJpg(bytes);
      if (image == null) return null;

      final w = image.width;
      final h = image.height;

      // Pre-compute exposure LUTs for Y channel only
      final underLUT = List<int>.generate(256, (v) {
        final n = v / 255.0;
        return (math.pow(n, 2.0).toDouble() * 255.0).round().clamp(0, 255);
      });

      final overLUT = List<int>.generate(256, (v) {
        final n = v / 255.0;
        return (math.pow(n, 0.5).toDouble() * 255.0).round().clamp(0, 255);
      });

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final pixel = image.getPixel(x, y);
          final r = pixel.r.toInt().clamp(0, 255);
          final g = pixel.g.toInt().clamp(0, 255);
          final b = pixel.b.toInt().clamp(0, 255);

          // === RGB → YCbCr conversion (BT.601 standard) ===
          final origY = (0.299 * r + 0.587 * g + 0.114 * b);
          final cb = 128 + (-0.168736 * r - 0.331264 * g + 0.5 * b);
          final cr = 128 + (0.5 * r - 0.418688 * g - 0.081312 * b);

          // === Y-channel exposure blending ===
          final origYInt = origY.round().clamp(0, 255);
          final underY = underLUT[origYInt].toDouble();
          final overY = overLUT[origYInt].toDouble();

          // Weight computation based on original Y (luminance)
          double wUnder, wNormal, wOver;

          if (origY > 200) {
            final t = ((origY - 200) / 55).clamp(0.0, 1.0);
            wUnder = 0.5 + 0.4 * t;
            wNormal = 0.4 - 0.3 * t;
            wOver = 0.1 - 0.1 * t;
          } else if (origY > 140) {
            final t = ((origY - 140) / 60).clamp(0.0, 1.0);
            wUnder = 0.2 + 0.3 * t;
            wNormal = 0.7 - 0.2 * t;
            wOver = 0.1 - 0.1 * t;
          } else if (origY < 55) {
            final t = ((55 - origY) / 55).clamp(0.0, 1.0);
            wOver = 0.5 + 0.4 * t;
            wNormal = 0.4 - 0.3 * t;
            wUnder = 0.1 - 0.1 * t;
          } else if (origY < 115) {
            final t = ((115 - origY) / 60).clamp(0.0, 1.0);
            wOver = 0.2 + 0.3 * t;
            wNormal = 0.7 - 0.2 * t;
            wUnder = 0.1 - 0.1 * t;
          } else {
            wUnder = 0.15;
            wNormal = 0.7;
            wOver = 0.15;
          }

          wUnder = wUnder.clamp(0.0, 1.0);
          wNormal = wNormal.clamp(0.0, 1.0);
          wOver = wOver.clamp(0.0, 1.0);
          final total = wUnder + wNormal + wOver;
          wUnder /= total;
          wNormal /= total;
          wOver /= total;

          // Blend Y only
          final newY = (underY * wUnder + origY * wNormal + overY * wOver);

          // === YCbCr → RGB conversion (using NEW Y + ORIGINAL Cb/Cr) ===
          // Ito ang key: yung Cb/Cr (color info) ay hindi natin ginalaw.
          // Kaya same colors, iba lang yung brightness.
          final newR = (newY + 1.402 * (cr - 128)).round().clamp(0, 255);
          final newG = (newY - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)).round().clamp(0, 255);
          final newB = (newY + 1.772 * (cb - 128)).round().clamp(0, 255);

          image.setPixelRgb(x, y, newR, newG, newB);
        }
      }

      // NO saturation or contrast boost — pure luminance processing lang
      final jpg = img.encodeJpg(image, quality: 92);
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
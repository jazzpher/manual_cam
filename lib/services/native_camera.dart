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

  /// Regular capture (JPEG or RAW+JPEG).
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
          if (croppedJpegPath != null) {
            paths['jpeg'] = croppedJpegPath;
          }
        } catch (e) {
          print('⚠️ JPEG crop failed: $e');
        }
      }

      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) {
          await Gal.requestAccess(toAlbum: true);
        }

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
      throw Exception('Capture failed: ${e.message}');
    }
  }

  /// === HDR+ MODE ===
  /// Capture 3 bracketed exposures (-2, 0, +2 EV) tapos blend them into a single
  /// tone-mapped JPEG. Ganito ang idea:
  /// - Highlights (bright areas) → gamitin yung UNDEREXPOSED (-2 EV) photo
  /// - Shadows (dark areas) → gamitin yung OVEREXPOSED (+2 EV) photo
  /// - Midtones → gamitin yung NORMAL (0 EV) photo
  ///
  /// Weighted blend based sa luminance ng normal exposure.
  Future<String> captureHDRBlend() async {
    try {
      // Kunin ang 3 bracket photos mula sa native side
      final result = await _channel.invokeMethod('captureBracket');
      if (result == null || result is! List) {
        throw Exception('Bracket capture returned null');
      }

      final photoPaths = result.map((p) => p.toString()).toList();
      if (photoPaths.length != 3) {
        throw Exception('Expected 3 bracket photos, got ${photoPaths.length}');
      }

      print('📸 Blending 3 bracket photos into HDR...');

      // Blend the 3 photos
      final blendedPath = await _blendBracketPhotos(
        underexposedPath: photoPaths[0], // -2 EV
        normalPath: photoPaths[1],       //  0 EV
        overexposedPath: photoPaths[2],  // +2 EV
      );

      // Save to Photos app
      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) {
          await Gal.requestAccess(toAlbum: true);
        }
        await Gal.putImage(blendedPath, album: 'ManualCam');
        print('✅ HDR+ blended image saved to Photos');
      } catch (e) {
        print('❌ Photos save error: $e');
      }

      // Cleanup temp bracket files (para hindi mag-clog)
      for (final p in photoPaths) {
        try {
          await File(p).delete();
        } catch (_) {}
      }

      return blendedPath;
    } on PlatformException catch (e) {
      throw Exception('HDR+ capture failed: ${e.message}');
    }
  }

  /// Blend 3 bracket photos using luminance-weighted merge.
  /// Ito ang core ng "HDR+" — para saktong exposure sa lahat ng parte ng photo.
  Future<String> _blendBracketPhotos({
    required String underexposedPath,
    required String normalPath,
    required String overexposedPath,
  }) async {
    // Decode all 3 photos
    final under = img.decodeJpg(await File(underexposedPath).readAsBytes());
    final normal = img.decodeJpg(await File(normalPath).readAsBytes());
    final over = img.decodeJpg(await File(overexposedPath).readAsBytes());

    if (under == null || normal == null || over == null) {
      throw Exception('Failed to decode bracket photos');
    }

    // All 3 must be same size (from same camera, same session)
    final w = normal.width;
    final h = normal.height;

    if (under.width != w || over.width != w) {
      throw Exception('Bracket photos have mismatched dimensions');
    }

    print('📸 Blending ${w}x$h photos...');

    // Create output image
    final result = img.Image(width: w, height: h);

    // For each pixel, compute weighted blend based on normal exposure luminance
    // Weighting logic:
    // - If pixel sa normal ay OVEREXPOSED (bright, >200) → gamitin yung under
    // - If pixel sa normal ay UNDEREXPOSED (dark, <60) → gamitin yung over
    // - Kung mid → mix of normal at neighbors
    //
    // Gumamit tayo ng smooth transitions (weight curves) para hindi visible ang seams.

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final nPix = normal.getPixel(x, y);
        final uPix = under.getPixel(x, y);
        final oPix = over.getPixel(x, y);

        // Compute luminance ng normal pixel (0-255)
        final nR = nPix.r.toDouble();
        final nG = nPix.g.toDouble();
        final nB = nPix.b.toDouble();
        final lum = 0.299 * nR + 0.587 * nG + 0.114 * nB;

        // Compute weights (each 0.0 to 1.0, summing to 1.0)
        double wUnder, wNormal, wOver;

        if (lum > 200) {
          // Very bright — favor under
          final t = ((lum - 200) / 55).clamp(0.0, 1.0);
          wUnder = 0.5 + 0.5 * t;
          wNormal = 0.5 - 0.4 * t;
          wOver = 0.1 - 0.1 * t;
        } else if (lum > 140) {
          // Highlights — mix under+normal
          final t = ((lum - 140) / 60).clamp(0.0, 1.0);
          wUnder = 0.2 + 0.3 * t;
          wNormal = 0.7 - 0.2 * t;
          wOver = 0.1 - 0.1 * t;
        } else if (lum < 55) {
          // Very dark — favor over
          final t = ((55 - lum) / 55).clamp(0.0, 1.0);
          wOver = 0.5 + 0.5 * t;
          wNormal = 0.5 - 0.4 * t;
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

        // Ensure non-negative and normalize
        wUnder = wUnder.clamp(0.0, 1.0);
        wNormal = wNormal.clamp(0.0, 1.0);
        wOver = wOver.clamp(0.0, 1.0);
        final total = wUnder + wNormal + wOver;
        wUnder /= total;
        wNormal /= total;
        wOver /= total;

        // Weighted blend of RGB channels
        final r = (uPix.r * wUnder + nPix.r * wNormal + oPix.r * wOver).round().clamp(0, 255);
        final g = (uPix.g * wUnder + nPix.g * wNormal + oPix.g * wOver).round().clamp(0, 255);
        final b = (uPix.b * wUnder + nPix.b * wNormal + oPix.b * wOver).round().clamp(0, 255);

        result.setPixelRgb(x, y, r, g, b);
      }
    }

    // Apply gentle contrast + saturation boost para pop
    final adjusted = img.adjustColor(result, contrast: 1.08, saturation: 1.1);

    // Encode as JPEG
    final jpg = img.encodeJpg(adjusted, quality: 92);

    // Save
    final tmpDir = Directory.systemTemp;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final outPath = '${tmpDir.path}/hdrplus_$timestamp.jpg';
    await File(outPath).writeAsBytes(jpg);

    print('✅ HDR+ blend saved: $outPath');
    return outPath;
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

      final cropped = img.copyCrop(
        decoded,
        x: offsetX,
        y: offsetY,
        width: newW,
        height: newH,
      );

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
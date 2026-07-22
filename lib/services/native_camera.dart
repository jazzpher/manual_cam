import 'dart:io';
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

  /// Capture at save sa Photos app.
  /// Kapag naka-RAW mode + zoomed, i-software crop natin yung JPEG (RAW/DNG ay
  /// hindi na natin ino-crop kasi editable pa rin sya sa Lightroom via crop tool).
  ///
  /// Returns: {'jpeg': path, 'raw': path (optional), 'zoom': '1.5' (as string)}
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

      // Halide-style: if RAW mode + zoom > 1.0x, apply software crop sa JPEG
      // para tumugma yung final image sa zoom level ng preview
      if (softwareZoom > 1.01 && paths['raw'] != null && paths['jpeg'] != null) {
        print('📸 Applying software zoom crop: ${softwareZoom}x');

        // Crop the JPEG to match zoom
        try {
          final croppedJpegPath = await _softwareZoomCrop(paths['jpeg']!, softwareZoom);
          if (croppedJpegPath != null) {
            paths['jpeg'] = croppedJpegPath;
            print('✅ JPEG software-zoomed to ${softwareZoom}x');
          }
        } catch (e) {
          print('⚠️ JPEG crop failed: $e (keeping original)');
        }

        // Crop the RAW/DNG din para consistent
        // NOTE: pure Dart image package HINDI kayang mag-decode ng DNG.
        // Kaya isu-skip natin. Sa Lightroom, ma-a-adjust naman ng user manually.
        // OR: puwedeng i-save with metadata na crop hint, pero yun ay complex.
        // Ang solusyon: leave DNG untouched (full sensor), i-crop lang JPEG.
        // Yung user pag nag-Lightroom, makikita nila yung full sensor DNG
        // at manual nila ma-c-crop.
      }

      // Save each file to Photos app
      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) {
          await Gal.requestAccess(toAlbum: true);
        }

        if (paths['jpeg'] != null) {
          await Gal.putImage(paths['jpeg']!, album: 'ManualCam');
          print('✅ JPEG saved to Photos: ${paths['jpeg']}');
        }

        if (paths['raw'] != null) {
          await Gal.putImage(paths['raw']!, album: 'ManualCam');
          print('✅ RAW/DNG saved to Photos: ${paths['raw']}');
        }
      } catch (e) {
        print('❌ Photos save error: $e');
      }

      // Add zoom as metadata for UI feedback
      paths['zoom'] = softwareZoom.toStringAsFixed(1);
      return paths;
    } on PlatformException catch (e) {
      throw Exception('Capture failed: ${e.message}');
    }
  }

  /// Center-crop a JPEG file to simulate optical zoom.
  /// Returns path to the new cropped file (original is preserved).
  Future<String?> _softwareZoomCrop(String jpegPath, double zoomFactor) async {
    if (zoomFactor <= 1.01) return jpegPath;

    try {
      final file = File(jpegPath);
      final bytes = await file.readAsBytes();

      final decoded = img.decodeJpg(bytes);
      if (decoded == null) return null;

      // Center crop by zoomFactor
      // At zoom = 2.0x, keep 50% ng pixels (1/2)
      // At zoom = 3.0x, keep 33% (1/3)
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

      // Re-encode as JPEG
      final croppedBytes = img.encodeJpg(cropped, quality: 92);

      // Write to new file
      final newPath = jpegPath.replaceFirst('.jpg', '_zoom.jpg');
      final newFile = File(newPath);
      await newFile.writeAsBytes(croppedBytes);

      return newPath;
    } catch (e) {
      print('Software crop error: $e');
      return null;
    }
  }
}
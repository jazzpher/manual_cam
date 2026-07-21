import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;

class ManualCamera {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _initialized = false;

  // Real camera capabilities (iOS limits)
  double _minISO = 24;
  double _maxISO = 1600;
  double _currentISO = 100;
  double _currentShutterSpeed = 1 / 60;
  double _currentExposureBias = 0.0;
  double _currentZoom = 1.0;
  final bool _supportsRAW = false;

  CameraController? get controller => _controller;
  bool get isInitialized => _initialized && _controller != null;

  /// Native aspect ratio ng preview sa PORTRAIT (width/height).
  /// iPhone camera usually 3:4 in portrait (0.75).
  double? get nativePortraitAspectRatio {
    if (_controller == null || !_controller!.value.isInitialized) return null;
    return 1 / _controller!.value.aspectRatio;
  }

  Future<void> initialize() async {
    if (_initialized && _controller != null) return;

    final cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted) {
      throw Exception('Camera permission denied. Please enable it in Settings.');
    }

    _cameras = await availableCameras();
    if (_cameras.isEmpty) {
      throw Exception('No cameras found on this device.');
    }

    final backCamera = _cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      backCamera,
      ResolutionPreset.max,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await _controller!.initialize();

    try {
      await _controller!.getMinExposureOffset();
      await _controller!.getMaxExposureOffset();
      _minISO = 24;
      _maxISO = 1600;
    } catch (e) {
      print('Could not get exposure range: $e');
    }

    _currentZoom = 1.0;
    try {
      await _controller!.setZoomLevel(_currentZoom);
    } catch (_) {}

    _initialized = true;
    print('✅ Real camera initialized: ${backCamera.name}');
    print('   Native preview size: ${_controller!.value.previewSize}');
  }

  Future<Map<String, dynamic>> getCapabilities() async {
    if (!isInitialized) await initialize();

    return {
      'minISO': _minISO,
      'maxISO': _maxISO,
      'supportsRAW': _supportsRAW,
      'maxZoom': 10.0,
    };
  }

  Future<void> setISO(double iso) async {
    if (!isInitialized) return;
    _currentISO = iso.clamp(_minISO, _maxISO);
    print('📸 ISO requested: $_currentISO (simulated - plugin limitation)');
  }

  Future<void> setShutterSpeed(double seconds) async {
    if (!isInitialized) return;
    _currentShutterSpeed = seconds;
    print('📸 Shutter speed requested: ${_formatShutterSpeed(seconds)} (simulated)');
  }

  Future<void> setExposureBias(double bias) async {
    if (!isInitialized || _controller == null) return;
    _currentExposureBias = bias.clamp(-4.0, 4.0);

    try {
      await _controller!.setExposureOffset(_currentExposureBias);
      print('📸 EV set to: $_currentExposureBias');
    } catch (e) {
      print('Exposure offset not supported: $e');
    }
  }

  Future<void> setZoom(double factor) async {
    if (!isInitialized || _controller == null) return;
    _currentZoom = factor.clamp(1.0, 10.0);

    try {
      await _controller!.setZoomLevel(_currentZoom);
      print('📸 Zoom set to: $_currentZoom x');
    } catch (e) {
      print('Zoom failed: $e');
    }
  }

  /// Capture, crop to aspect ratio (kung binigay), tapos save sa Photos app.
  Future<String> capturePhoto({
    bool raw = true,
    double? portraitAspectRatio,
  }) async {
    if (!isInitialized || _controller == null) {
      throw Exception('Camera not initialized');
    }

    try {
      final XFile file = await _controller!.takePicture();

      final Directory appDir = await getApplicationDocumentsDirectory();
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String rawPath = path.join(appDir.path, 'manualcam_$timestamp.jpg');
      await file.saveTo(rawPath);

      String finalPath = rawPath;
      if (portraitAspectRatio != null) {
        try {
          finalPath = await _cropToAspectRatio(rawPath, portraitAspectRatio);
        } catch (e) {
          print('⚠️ Crop failed, using original: $e');
          finalPath = rawPath;
        }
      }

      try {
        final hasAccess = await Gal.hasAccess(toAlbum: true);
        if (!hasAccess) {
          await Gal.requestAccess(toAlbum: true);
        }
        await Gal.putImage(finalPath, album: 'ManualCam');
        print('✅ Saved to Photos app (album: ManualCam)');
      } catch (e) {
        print('❌ Photos save error: $e');
      }

      return finalPath;
    } catch (e) {
      print('Capture error: $e');
      throw Exception('Failed to capture photo: $e');
    }
  }

  Future<String> _cropToAspectRatio(String imagePath, double portraitAspectRatio) async {
    final File srcFile = File(imagePath);
    final bytes = await srcFile.readAsBytes();

    img.Image? decoded = img.decodeJpg(bytes);
    if (decoded == null) throw Exception('Failed to decode JPEG');

    decoded = img.bakeOrientation(decoded);

    final int w = decoded.width;
    final int h = decoded.height;

    final bool imageIsPortrait = h >= w;

    double targetAspect;
    if (imageIsPortrait) {
      targetAspect = portraitAspectRatio;
    } else {
      targetAspect = 1 / portraitAspectRatio;
    }

    final double currentAspect = w / h;

    int cropW, cropH;
    if (currentAspect > targetAspect) {
      cropH = h;
      cropW = (h * targetAspect).round();
    } else {
      cropW = w;
      cropH = (w / targetAspect).round();
    }

    final int cropX = ((w - cropW) / 2).round();
    final int cropY = ((h - cropH) / 2).round();

    final cropped = img.copyCrop(decoded, x: cropX, y: cropY, width: cropW, height: cropH);
    final jpg = img.encodeJpg(cropped, quality: 95);

    final String croppedPath = imagePath.replaceFirst('.jpg', '_cropped.jpg');
    await File(croppedPath).writeAsBytes(jpg);

    return croppedPath;
  }

  Future<void> setFocusPoint(double x, double y) async {
    if (!isInitialized || _controller == null) return;

    try {
      await _controller!.setFocusPoint(Offset(x, y));
      print('📸 Focus point set: ($x, $y)');
    } catch (e) {
      print('Focus point error: $e');
    }
  }

  Future<void> setManualFocus(double lensPosition) async {
    print('📸 Manual focus requested (limited support)');
  }

  String _formatShutterSpeed(double seconds) {
    if (seconds >= 1) return '${seconds.toInt()}"';
    return '1/${(1 / seconds).round()}';
  }

  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
    _initialized = false;
    print('📸 Camera disposed');
  }

  Widget getPreviewWidget() {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.amber));
    }
    return CameraPreview(_controller!);
  }
}
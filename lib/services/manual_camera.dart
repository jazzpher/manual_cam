import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

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
  bool _supportsRAW = false; // Limited on standard camera plugin

  CameraController? get controller => _controller;
  bool get isInitialized => _initialized && _controller != null;

  Future<void> initialize() async {
    if (_initialized && _controller != null) return;

    // Request camera permission
    final cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted) {
      throw Exception('Camera permission denied. Please enable it in Settings.');
    }

    // Get available cameras
    _cameras = await availableCameras();
    if (_cameras.isEmpty) {
      throw Exception('No cameras found on this device.');
    }

    // Use back camera (index 0)
    final backCamera = _cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      backCamera,
      ResolutionPreset.high, // Good quality for manual feel
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg, // JPEG for now (RAW needs advanced setup)
    );

    await _controller!.initialize();

    // Get real exposure range if available
    try {
      final minExposure = await _controller!.getMinExposureOffset();
      final maxExposure = await _controller!.getMaxExposureOffset();
      _minISO = 24; // Camera plugin doesn't expose ISO directly
      _maxISO = 1600;
      // We use exposureOffset as EV
    } catch (e) {
      print('Could not get exposure range: $e');
    }

    // Set initial zoom
    _currentZoom = 1.0;
    try {
      await _controller!.setZoomLevel(_currentZoom);
    } catch (_) {}

    _initialized = true;
    print('✅ Real camera initialized: ${backCamera.name}');
  }

  Future<Map<String, dynamic>> getCapabilities() async {
    if (!isInitialized) await initialize();

    return {
      'minISO': _minISO,
      'maxISO': _maxISO,
      'supportsRAW': _supportsRAW, // Will be false for now
      'maxZoom': 10.0, // Approximate
    };
  }

  Future<void> setISO(double iso) async {
    if (!isInitialized) return;

    _currentISO = iso.clamp(_minISO, _maxISO);
    // Note: The camera plugin does NOT support direct ISO control on iOS.
    // We simulate it in UI. For real manual control, native AVFoundation needed.
    print('📸 ISO requested: $_currentISO (simulated - plugin limitation)');
  }

  Future<void> setShutterSpeed(double seconds) async {
    if (!isInitialized) return;

    _currentShutterSpeed = seconds;
    // Shutter speed is not directly controllable via camera plugin on iOS.
    print('📸 Shutter speed requested: ${_formatShutterSpeed(seconds)} (simulated)');
  }

  Future<void> setExposureBias(double bias) async {
    if (!isInitialized || _controller == null) return;

    _currentExposureBias = bias.clamp(-4.0, 4.0);

    try {
      // Use exposureOffset (EV compensation)
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

  Future<String?> capturePhoto({bool raw = true}) async {
    if (!isInitialized || _controller == null) {
      throw Exception('Camera not initialized');
    }

    try {
      // Take picture
      final XFile file = await _controller!.takePicture();

      // Get app documents directory
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();

      final String extension = raw ? 'jpg' : 'jpg'; // Real RAW not supported yet
      final String fileName = 'manualcam_$timestamp.$extension';
      final String savedPath = path.join(appDir.path, fileName);

      // Copy to permanent location
      await file.saveTo(savedPath);

      print('📸 REAL photo saved: $savedPath (RAW mode: $raw - using JPEG)');

      return savedPath;
    } catch (e) {
      print('Capture error: $e');
      throw Exception('Failed to capture photo: $e');
    }
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
    // Limited support
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

  // Helper to get preview widget
  Widget getPreviewWidget() {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.amber));
    }
    return CameraPreview(_controller!);
  }
}

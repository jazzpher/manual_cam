import 'package:flutter/material.dart';
import 'widgets/camera_preview.dart';
import 'widgets/controls_overlay.dart';
import 'services/manual_camera.dart';

void main() {
  runApp(const ManualCamApp());
}

class ManualCamApp extends StatelessWidget {
  const ManualCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ManualCam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Colors.amber,
          secondary: Colors.amber,
        ),
      ),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final ManualCamera _camera = ManualCamera();
  bool _isInitialized = false;
  bool _isRawEnabled = false; // Real RAW not supported with camera plugin
  double _iso = 100;
  double _minISO = 24;
  double _maxISO = 1600;
  String _shutterSpeed = '1/60';
  double _exposureBias = 0.0;
  double _zoom = 1.0;

  final List<double> _shutterSpeedValues = [
    1 / 8000, 1 / 4000, 1 / 2000, 1 / 1000, 1 / 500, 1 / 250,
    1 / 125, 1 / 60, 1 / 30, 1 / 15, 1 / 8, 1 / 4, 1 / 2,
    1, 2, 5, 10, 30,
  ];

  String _aspectRatio = '4:3';
  final List<String> _aspectRatios = ['4:3', '16:9', '1:1', '3:2'];
  bool _showISOSlider = false;
  bool _showEVSlider = false;
  bool _isCapturing = false;
  String? _lastPhotoPath;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    setState(() {
      _statusMessage = 'Initializing real camera...';
    });

    try {
      await _camera.initialize();
      final capabilities = await _camera.getCapabilities();

      setState(() {
        _minISO = capabilities['minISO'] ?? 24.0;
        _maxISO = capabilities['maxISO'] ?? 1600.0;
        _isRawEnabled = capabilities['supportsRAW'] ?? false;
        _isInitialized = true;
        _statusMessage = '';
      });
    } catch (e) {
      print('Camera init error: $e');
      setState(() {
        _statusMessage = 'Error: $e\n\nPlease grant camera permission and restart the app.';
      });
    }
  }

  Future<void> _setISO(double value) async {
    await _camera.setISO(value);
    setState(() => _iso = value);
  }

  Future<void> _setShutterSpeed(double seconds) async {
    await _camera.setShutterSpeed(seconds);
    setState(() => _shutterSpeed = _formatShutterSpeed(seconds));
  }

  Future<void> _setExposureBias(double value) async {
    await _camera.setExposureBias(value);
    setState(() => _exposureBias = value);
  }

  Future<void> _setZoom(double factor) async {
    await _camera.setZoom(factor);
    setState(() => _zoom = factor);
  }

  Future<void> _capturePhoto() async {
    if (_isCapturing) return;

    setState(() {
      _isCapturing = true;
      _statusMessage = 'Capturing...';
    });

    try {
      final path = await _camera.capturePhoto(raw: _isRawEnabled);

      if (path != null && mounted) {
        setState(() {
          _lastPhotoPath = path;
          _statusMessage = '';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isRawEnabled
                  ? '📸 Photo saved! (Note: RAW not fully supported yet)'
                  : '📸 Real photo captured & saved!',
            ),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Capture Error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
        setState(() => _statusMessage = '');
      }
    }

    setState(() => _isCapturing = false);
  }

  String _formatShutterSpeed(double seconds) {
    if (seconds >= 1) return '${seconds.toInt()}"';
    return '1/${(1 / seconds).round()}';
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.amber),
              const SizedBox(height: 24),
              Text(
                _statusMessage.isEmpty ? 'Initializing real camera...' : _statusMessage,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              if (_statusMessage.contains('permission'))
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: ElevatedButton(
                    onPressed: _initCamera,
                    child: const Text('Retry Camera Init'),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Real camera preview (or simulated fallback)
          CameraPreview(camera: _camera),

          // Bottom gradient for controls
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 260,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
          ),

          // Controls
          ControlsOverlay(
            iso: _iso,
            minISO: _minISO,
            maxISO: _maxISO,
            shutterSpeed: _shutterSpeed,
            shutterSpeedValues: _shutterSpeedValues,
            exposureBias: _exposureBias,
            zoom: _zoom,
            aspectRatio: _aspectRatio,
            aspectRatios: _aspectRatios,
            isRawEnabled: _isRawEnabled,
            isCapturing: _isCapturing,
            onISOChanged: _setISO,
            onShutterSpeedChanged: _setShutterSpeed,
            onExposureBiasChanged: _setExposureBias,
            onZoomChanged: _setZoom,
            onAspectRatioChanged: (ratio) => setState(() => _aspectRatio = ratio),
            onCapture: _capturePhoto,
            onToggleRaw: (value) => setState(() => _isRawEnabled = value),
            showISOSlider: _showISOSlider,
            onToggleISOSlider: () => setState(() => _showISOSlider = !_showISOSlider),
            showEVSlider: _showEVSlider,
            onToggleEVSlider: () => setState(() => _showEVSlider = !_showEVSlider),
          ),

          // Status / note banner (top)
          if (_statusMessage.isNotEmpty)
            Positioned(
              top: 60,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber.withOpacity(0.5)),
                ),
                child: Text(
                  _statusMessage,
                  style: const TextStyle(color: Colors.amber, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ),

          // Info banner about limitations
          Positioned(
            top: 40,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'REAL iPhone Camera',
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
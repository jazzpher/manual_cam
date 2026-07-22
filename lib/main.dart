import 'package:flutter/material.dart';
import 'services/native_camera.dart';
import 'widgets/camera_preview.dart';
import 'widgets/controls_overlay.dart';

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
  final NativeCamera _camera = NativeCamera();

  bool _isInitialized = false;
  String _statusMessage = 'Starting native camera...';

  double _iso = 100;
  double _minISO = 24;
  double _maxISO = 3200;
  String _shutterSpeed = '1/60';
  double _shutterSeconds = 1 / 60;
  double _exposureBias = 0.0;
  double _zoom = 1.0;
  double _maxZoom = 10.0;
  double _focus = 0.5;
  bool _isHDREnabled = false;
  bool _isRawEnabled = false;
  bool _supportsRAW = false;
  String _flashMode = 'off';
  String _aspectRatio = '4:3';
  bool _isCapturing = false;

  bool _showISOSlider = false;
  bool _showEVSlider = false;
  bool _showShutterPicker = false;
  bool _showFocusSlider = false;
  bool _showZoomSlider = false;

  Offset? _tapFocusPoint;

  final List<double> _shutterSpeedValues = [
    1 / 8000, 1 / 4000, 1 / 2000, 1 / 1000, 1 / 500, 1 / 250,
    1 / 125, 1 / 60, 1 / 30, 1 / 15, 1 / 8, 1 / 4, 1 / 2,
    1, 2, 5, 10, 30,
  ];

  final List<String> _aspectRatios = ['4:3', '16:9', '1:1', '3:2'];

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      await _camera.initialize();
      setState(() {
        _minISO = _camera.minISO;
        _maxISO = _camera.maxISO;
        _maxZoom = _camera.maxZoom;
        _supportsRAW = _camera.supportsRAW;
        _iso = _iso.clamp(_minISO, _maxISO);
        _isInitialized = true;
        _statusMessage = '';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Camera init failed:\n$e\n\nPlease grant camera permission in Settings.';
      });
    }
  }

  String _formatShutter(double s) {
    if (s >= 1) return '${s.toInt()}"';
    return '1/${(1 / s).round()}';
  }

  Future<void> _setISO(double v) async {
    setState(() => _iso = v);
    await _camera.setISO(v);
  }

  Future<void> _setShutter(double sec) async {
    setState(() {
      _shutterSeconds = sec;
      _shutterSpeed = _formatShutter(sec);
    });
    await _camera.setShutterSpeed(sec);
  }

  Future<void> _setEV(double v) async {
    setState(() => _exposureBias = v);
    await _camera.setExposureBias(v);
  }

  Future<void> _setZoom(double v) async {
    setState(() => _zoom = v);
    await _camera.setZoom(v);
  }

  Future<void> _setFocus(double v) async {
    setState(() => _focus = v);
    await _camera.setFocus(v);
  }

  Future<void> _setFlash(String mode) async {
    setState(() => _flashMode = mode);
    await _camera.setFlashMode(mode);
  }

  Future<void> _toggleHDR() async {
    setState(() => _isHDREnabled = !_isHDREnabled);
    await _camera.setHDR(_isHDREnabled);
  }

  Future<void> _toggleRAW() async {
    if (!_supportsRAW) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ RAW not supported on this device'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    setState(() => _isRawEnabled = !_isRawEnabled);
    await _camera.setRAW(_isRawEnabled);
  }

  Future<void> _onPreviewTap(double x, double y) async {
    setState(() {
      _tapFocusPoint = Offset(x, y);
    });
    await _camera.focusAtPoint(x, y);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _tapFocusPoint = null);
    });
  }

  Future<void> _capturePhoto() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final paths = await _camera.capturePhoto();
      if (mounted) {
        final hasRaw = paths.containsKey('raw');
        final message = hasRaw
            ? '📸 RAW + JPEG saved to Photos'
            : '📸 JPEG saved to Photos';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Capture error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }

    if (mounted) setState(() => _isCapturing = false);
  }

  void _closeAllPopups() {
    setState(() {
      _showISOSlider = false;
      _showEVSlider = false;
      _showShutterPicker = false;
      _showFocusSlider = false;
      _showZoomSlider = false;
    });
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  _statusMessage,
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _initCamera,
                child: const Text('Retry'),
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
          Positioned.fill(
            child: NativeCameraPreview(
              aspectRatio: _aspectRatio,
              onTap: _onPreviewTap,
            ),
          ),

          if (_tapFocusPoint != null)
            _buildFocusReticle(_tapFocusPoint!),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 320,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
          ),

          ControlsOverlay(
            iso: _iso,
            minISO: _minISO,
            maxISO: _maxISO,
            shutterSpeed: _shutterSpeed,
            shutterSpeedValues: _shutterSpeedValues,
            exposureBias: _exposureBias,
            zoom: _zoom,
            maxZoom: _maxZoom,
            focus: _focus,
            aspectRatio: _aspectRatio,
            aspectRatios: _aspectRatios,
            flashMode: _flashMode,
            isHDREnabled: _isHDREnabled,
            isRawEnabled: _isRawEnabled,
            isCapturing: _isCapturing,
            onISOChanged: _setISO,
            onShutterSpeedChanged: _setShutter,
            onExposureBiasChanged: _setEV,
            onZoomChanged: _setZoom,
            onFocusChanged: _setFocus,
            onAspectRatioChanged: (r) => setState(() => _aspectRatio = r),
            onFlashModeChanged: _setFlash,
            onCapture: _capturePhoto,
            onToggleHDR: _toggleHDR,
            onToggleRAW: _toggleRAW,
            onCloseAllPopups: _closeAllPopups,
            showISOSlider: _showISOSlider,
            onToggleISOSlider: () {
              final wasOpen = _showISOSlider;
              _closeAllPopups();
              setState(() => _showISOSlider = !wasOpen);
            },
            showEVSlider: _showEVSlider,
            onToggleEVSlider: () {
              final wasOpen = _showEVSlider;
              _closeAllPopups();
              setState(() => _showEVSlider = !wasOpen);
            },
            showShutterPicker: _showShutterPicker,
            onToggleShutterPicker: () {
              final wasOpen = _showShutterPicker;
              _closeAllPopups();
              setState(() => _showShutterPicker = !wasOpen);
            },
            showFocusSlider: _showFocusSlider,
            onToggleFocusSlider: () {
              final wasOpen = _showFocusSlider;
              _closeAllPopups();
              setState(() => _showFocusSlider = !wasOpen);
            },
            showZoomSlider: _showZoomSlider,
            onToggleZoomSlider: () {
              final wasOpen = _showZoomSlider;
              _closeAllPopups();
              setState(() => _showZoomSlider = !wasOpen);
            },
          ),

          Positioned(
            top: 40,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _isRawEnabled ? '$_aspectRatio · RAW+JPEG' : '$_aspectRatio · JPEG',
                style: const TextStyle(
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

  Widget _buildFocusReticle(Offset point) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: TweenAnimationBuilder<double>(
            key: ValueKey(point),
            tween: Tween<double>(begin: 1.5, end: 1.0),
            duration: const Duration(milliseconds: 300),
            builder: (context, scale, _) => Transform.scale(
              scale: scale,
              child: Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.amber, width: 2),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
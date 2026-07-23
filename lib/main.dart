import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/native_camera.dart';
import 'widgets/camera_preview.dart';
import 'widgets/controls_overlay.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]).then((
    _,
  ) {
    runApp(const ManualCamApp());
  });
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
  double _exposureBias = 0.0;
  double _zoom = 1.0;
  static const double _natural48Zoom = 756 / 409;
  double _maxZoom = 10.0;
  double _focus = 0.5;
  bool _isHDREnabled = false;
  bool _isRawEnabled = false;
  bool _isNatural48Enabled = false;
  bool _isFrameModeEnabled = false;
  bool _isExposureAuto = true;
  bool _isFocusAuto = true;
  bool _supportsRAW = false;
  String _flashMode = 'off';
  String _aspectRatio = '4:3';
  bool _isCapturing = false;

  // === ACTIVE DIAL STATE ===
  // Kung anong setting ang currently naka-open sa ruler dial
  SettingType _activeDial = SettingType.none;

  int _uiOrientation = 0;
  Timer? _orientationPollTimer;

  final List<double> _shutterSpeedValues = [
    1 / 8000,
    1 / 4000,
    1 / 2000,
    1 / 1000,
    1 / 500,
    1 / 250,
    1 / 125,
    1 / 60,
    1 / 30,
    1 / 15,
    1 / 8,
    1 / 4,
    1 / 2,
    1,
    2,
    5,
    10,
    30,
  ];

  final List<String> _aspectRatios = ['4:3', '16:9', '1:1', '3:2'];

  @override
  void initState() {
    super.initState();
    _initCamera();
    _startOrientationPolling();
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
        _statusMessage =
            'Camera init failed:\n$e\n\nPlease grant camera permission in Settings.';
      });
    }
  }

  void _startOrientationPolling() {
    _orientationPollTimer = Timer.periodic(const Duration(milliseconds: 300), (
      _,
    ) async {
      try {
        final code = await _camera.getCurrentOrientationCode();
        if (code != _uiOrientation && mounted) {
          setState(() => _uiOrientation = code);
        }
      } catch (_) {
        // Keep the last known orientation when the native poll is unavailable.
      }
    });
  }

  String _formatShutter(double s) {
    if (s >= 1) return '${s.toInt()}"';
    return '1/${(1 / s).round()}';
  }

  Future<void> _setISO(double v) async {
    setState(() {
      _iso = v;
      _isExposureAuto = false;
    });
    await _camera.setISO(v);
  }

  Future<void> _setShutter(double sec) async {
    setState(() {
      _shutterSpeed = _formatShutter(sec);
      _isExposureAuto = false;
    });
    await _camera.setShutterSpeed(sec);
  }

  Future<void> _setEV(double v) async {
    setState(() {
      _exposureBias = v;
      _isExposureAuto = true;
    });
    await _camera.setExposureBias(v);
  }

  Future<void> _setZoom(double v) async {
    setState(() => _zoom = v);
    await _camera.setZoom(v);
  }

  Future<void> _setFocus(double v) async {
    setState(() {
      _focus = v;
      _isFocusAuto = false;
    });
    await _camera.setFocus(v);
  }

  Future<void> _setFlash(String mode) async {
    setState(() => _flashMode = mode);
    await _camera.setFlashMode(mode);
  }

  Future<void> _toggleHDR() async {
    if (_isFrameModeEnabled) return;
    setState(() => _isHDREnabled = !_isHDREnabled);
    await _camera.setHDR(_isHDREnabled);
  }

  Future<void> _toggleRAW() async {
    if (_isFrameModeEnabled) {
      await _camera.setFrameMode(false);
      if (mounted) {
        setState(() {
          _isFrameModeEnabled = false;
          _aspectRatio = '4:3';
          _zoom = 1.0;
        });
      }
    }

    if (_isNatural48Enabled) {
      await _camera.setNatural48Mode(false);
      if (mounted) {
        setState(() {
          _isNatural48Enabled = false;
          _zoom = 1.0;
        });
      }
    }

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

  Future<void> _toggleFrameMode() async {
    final enable = !_isFrameModeEnabled;
    final success = await _camera.setFrameMode(enable);
    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to switch 4K Frame mode'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isFrameModeEnabled = enable;
      _isExposureAuto = true;
      _isFocusAuto = true;
      _isNatural48Enabled = false;
      _isRawEnabled = false;
      _isHDREnabled = false;
      _flashMode = 'off';
      _zoom = 1.0;
      _aspectRatio = enable ? '16:9' : '4:3';
      _activeDial = SettingType.none;
    });

    if (enable) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final values = await _camera.getCurrentCameraValues();
      if (mounted && _isFrameModeEnabled) {
        setState(() {
          _iso = values['iso'] ?? _iso;
          final shutter = values['shutterSeconds'];
          if (shutter != null && shutter > 0) {
            _shutterSpeed = _formatShutter(shutter);
          }
          _focus = values['focus'] ?? _focus;
        });
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enable
              ? '4K Frame ON · Auto AE/AF · Manual override ready'
              : '4K Frame OFF · Photo mode restored',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _toggleNatural48() async {
    if (_isFrameModeEnabled) {
      await _camera.setFrameMode(false);
    }
    final enable = !_isNatural48Enabled;
    final success = await _camera.setNatural48Mode(enable);
    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to switch 48mm Natural mode'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isNatural48Enabled = enable;
      _isFrameModeEnabled = false;
      _isExposureAuto = true;
      _isFocusAuto = true;
      _isRawEnabled = false;
      _isHDREnabled = false;
      _flashMode = 'off';
      _exposureBias = 0.0;
      _zoom = enable ? _natural48Zoom : 1.0;
      _aspectRatio = '4:3';
      _activeDial = SettingType.none;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enable
              ? '48mm Natural ON · Auto AE/AF · High-quality JPEG'
              : '48mm Natural OFF · 1x camera restored',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // === DIAL SELECTION CALLBACK ===
  void _onSelectDial(SettingType type) {
    setState(() => _activeDial = type);
  }

  Future<void> _onPreviewTap(double x, double y) async {
    setState(() {
      _isExposureAuto = true;
      _isFocusAuto = true;
      _exposureBias = 0.0;
    });

    // A preview tap is the universal AUTO reset in every camera mode:
    // continuous AE/AF/AWB at the tapped point and zero EV compensation.
    await _camera.focusAtPoint(x, y);
    await Future<void>.delayed(const Duration(milliseconds: 350));

    final values = await _camera.getCurrentCameraValues();
    if (mounted) {
      setState(() {
        _iso = values['iso'] ?? _iso;
        final shutter = values['shutterSeconds'];
        if (shutter != null && shutter > 0) {
          _shutterSpeed = _formatShutter(shutter);
        }
        _focus = values['focus'] ?? _focus;
      });
    }
  }

  Future<void> _capturePhoto() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);

    try {
      final paths = _isFrameModeEnabled
          ? await _camera.captureVideoFrame(_aspectRatio)
          : await _camera.capturePhoto();
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

        final hasRaw = paths.containsKey('raw');
        final zoom = paths['zoom'] ?? '1.0';
        final zoomLabel = zoom == '1.0' ? '' : ' (${zoom}x)';
        final message = _isFrameModeEnabled
            ? '🎞️ 4K video frame saved$zoomLabel'
            : hasRaw
            ? '📸 RAW + JPEG saved$zoomLabel'
            : '📸 JPEG saved$zoomLabel';

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
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Capture error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }

    if (mounted) setState(() => _isCapturing = false);
  }

  String _modeLabel() {
    final parts = <String>[];
    if (_isRawEnabled) {
      parts.add('RAW+JPEG');
    } else {
      parts.add('JPEG');
    }
    if (_isNatural48Enabled) parts.add('48MM NATURAL');
    if (_isFrameModeEnabled) parts.add('4K FRAME');
    return parts.join(' · ');
  }

  @override
  void dispose() {
    _orientationPollTimer?.cancel();
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
              softwareZoom: _isRawEnabled ? _zoom : 1.0,
            ),
          ),

          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 340,
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
            isNatural48Enabled: _isNatural48Enabled,
            isFrameModeEnabled: _isFrameModeEnabled,
            isExposureAuto: _isExposureAuto,
            isFocusAuto: _isFocusAuto,
            isCapturing: _isCapturing,
            uiOrientation: _uiOrientation,
            activeDial: _activeDial,
            onISOChanged: _setISO,
            onShutterSpeedChanged: _setShutter,
            onExposureBiasChanged: _setEV,
            onZoomChanged: _setZoom,
            onFocusChanged: _setFocus,
            onAspectRatioChanged: (r) => setState(() => _aspectRatio = r),
            onFlashModeChanged: _setFlash,
            onSelectDial: _onSelectDial,
            onCapture: _capturePhoto,
            onToggleHDR: _toggleHDR,
            onToggleRAW: _toggleRAW,
            onToggleNatural48: _toggleNatural48,
            onToggleFrameMode: _toggleFrameMode,
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
                '$_aspectRatio · ${_modeLabel()} · ${_zoom.toStringAsFixed(1)}x',
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
}

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Setting types for the active dial
enum SettingType { none, shutter, iso, ev, focus, zoom }

class ControlsOverlay extends StatelessWidget {
  final double iso, minISO, maxISO, exposureBias, zoom, maxZoom, focus;
  final String shutterSpeed, aspectRatio, flashMode;
  final List<double> shutterSpeedValues;
  final List<String> aspectRatios;
  final bool isHDREnabled,
      isRawEnabled,
      isNatural48Enabled,
      isFrameModeEnabled,
      frameExposureAuto,
      frameFocusAuto,
      isCapturing;
  final int uiOrientation;
  final SettingType activeDial;
  final Function(double) onISOChanged,
      onShutterSpeedChanged,
      onExposureBiasChanged,
      onZoomChanged,
      onFocusChanged;
  final Function(String) onAspectRatioChanged, onFlashModeChanged;
  final Function(SettingType) onSelectDial;
  final VoidCallback onCapture,
      onToggleHDR,
      onToggleRAW,
      onToggleNatural48,
      onToggleFrameMode;

  const ControlsOverlay({
    super.key,
    required this.iso,
    required this.minISO,
    required this.maxISO,
    required this.shutterSpeed,
    required this.shutterSpeedValues,
    required this.exposureBias,
    required this.zoom,
    required this.maxZoom,
    required this.focus,
    required this.aspectRatio,
    required this.aspectRatios,
    required this.flashMode,
    required this.isHDREnabled,
    required this.isRawEnabled,
    required this.isNatural48Enabled,
    required this.isFrameModeEnabled,
    required this.frameExposureAuto,
    required this.frameFocusAuto,
    required this.isCapturing,
    required this.uiOrientation,
    required this.activeDial,
    required this.onISOChanged,
    required this.onShutterSpeedChanged,
    required this.onExposureBiasChanged,
    required this.onZoomChanged,
    required this.onFocusChanged,
    required this.onAspectRatioChanged,
    required this.onFlashModeChanged,
    required this.onSelectDial,
    required this.onCapture,
    required this.onToggleHDR,
    required this.onToggleRAW,
    required this.onToggleNatural48,
    required this.onToggleFrameMode,
  });

  double get _rotationAngle {
    switch (uiOrientation) {
      case 1:
        return -math.pi / 2;
      case 2:
        return math.pi;
      case 3:
        return math.pi / 2;
      default:
        return 0;
    }
  }

  Widget _rotate(Widget child) {
    return AnimatedRotation(
      turns: _rotationAngle / (2 * math.pi),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(),
          const Spacer(),
          _buildAspectRatioSelector(),
          const SizedBox(height: 8),
          // === RULER DIAL (lumalabas kapag may active setting) ===
          if (activeDial != SettingType.none) _buildRulerDial(),
          const SizedBox(height: 6),
          _buildSettingPicker(),
          const SizedBox(height: 12),
          _buildBottomControls(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: isFrameModeEnabled
                ? null
                : () {
                    final next = flashMode == 'off'
                        ? 'on'
                        : flashMode == 'on'
                        ? 'auto'
                        : 'off';
                    onFlashModeChanged(next);
                  },
            child: _rotate(
              _pill(
                icon: flashMode == 'off'
                    ? Icons.flash_off
                    : flashMode == 'on'
                    ? Icons.flash_on
                    : Icons.flash_auto,
                label: flashMode.toUpperCase(),
                color: flashMode == 'off' ? Colors.grey : Colors.amber,
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onToggleHDR,
            child: _rotate(
              _pill(
                label: 'HDR',
                color: isHDREnabled ? Colors.amber : Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onToggleRAW,
            child: _rotate(
              _pill(
                label: 'RAW',
                color: isRawEnabled ? Colors.amber : Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onToggleNatural48,
            child: _rotate(
              _pill(
                icon: Icons.camera_alt_outlined,
                label: '48MM',
                color: isNatural48Enabled ? Colors.amber : Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onToggleFrameMode,
            child: _rotate(
              _pill(
                icon: Icons.videocam_outlined,
                label: 'FRAME',
                color: isFrameModeEnabled
                    ? Colors.lightBlueAccent
                    : Colors.grey,
              ),
            ),
          ),
          const Spacer(),
          _rotate(_pill(label: 'MANUAL', color: Colors.amber)),
        ],
      ),
    );
  }

  Widget _pill({IconData? icon, required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: color, size: 12),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAspectRatioSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: aspectRatios.map((ratio) {
          final isSelected = ratio == aspectRatio;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: GestureDetector(
              onTap: () => onAspectRatioChanged(ratio),
              child: _rotate(
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.amber.withOpacity(0.3)
                        : Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isSelected ? Colors.amber : Colors.white24,
                      width: 1,
                    ),
                  ),
                  child: Text(
                    ratio,
                    style: TextStyle(
                      color: isSelected ? Colors.amber : Colors.white70,
                      fontSize: 11,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // === SETTING PICKER (5 buttons: SHUTTER, ISO, EV, FOCUS, ZOOM) ===
  Widget _buildSettingPicker() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _pickerButton(
            type: SettingType.shutter,
            label: 'SHUTTER',
            value:
                isNatural48Enabled || (isFrameModeEnabled && frameExposureAuto)
                ? 'AUTO'
                : shutterSpeed,
            enabled: !isNatural48Enabled,
          ),
          _pickerButton(
            type: SettingType.iso,
            label: 'ISO',
            value:
                isNatural48Enabled || (isFrameModeEnabled && frameExposureAuto)
                ? 'AUTO'
                : iso.toInt().toString(),
            enabled: !isNatural48Enabled,
          ),
          _pickerButton(
            type: SettingType.ev,
            label: 'EV',
            value: isNatural48Enabled
                ? 'AUTO'
                : '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)}',
            enabled: !isNatural48Enabled,
          ),
          _pickerButton(
            type: SettingType.focus,
            label: 'FOCUS',
            value: isNatural48Enabled || (isFrameModeEnabled && frameFocusAuto)
                ? 'AF'
                : focus.toStringAsFixed(2),
            enabled: !isNatural48Enabled,
          ),
          _pickerButton(
            type: SettingType.zoom,
            label: 'ZOOM',
            value: isNatural48Enabled ? '48mm' : '${zoom.toStringAsFixed(1)}x',
            enabled: !isNatural48Enabled,
          ),
        ],
      ),
    );
  }

  Widget _pickerButton({
    required SettingType type,
    required String label,
    required String value,
    bool enabled = true,
  }) {
    final isActive = enabled && activeDial == type;
    return GestureDetector(
      onTap: enabled
          ? () {
              // Tap toggle: if same active, close; else switch.
              onSelectDial(isActive ? SettingType.none : type);
            }
          : null,
      behavior: HitTestBehavior.opaque,
      child: _rotate(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: isActive
                ? Colors.amber.withOpacity(0.25)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isActive ? Colors.amber : Colors.transparent,
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: !enabled
                      ? Colors.white54
                      : isActive
                      ? Colors.amber
                      : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: !enabled
                      ? Colors.white38
                      : isActive
                      ? Colors.amber
                      : Colors.grey,
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // === RULER DIAL (horizontal swipeable ruler with tick marks) ===
  Widget _buildRulerDial() {
    // Get current, min, max, at label based on active setting
    double currentValue = 0;
    double minValue = 0;
    double maxValue = 1;
    String label = '';
    Function(double) callback = (_) {};
    int? divisions;

    switch (activeDial) {
      case SettingType.shutter:
        currentValue = _shutterIndex(
          _secondsFromLabel(shutterSpeed),
        ).toDouble();
        minValue = 0;
        maxValue = (shutterSpeedValues.length - 1).toDouble();
        label = shutterSpeed;
        divisions = shutterSpeedValues.length - 1;
        callback = (idx) {
          final i = idx.round().clamp(0, shutterSpeedValues.length - 1);
          onShutterSpeedChanged(shutterSpeedValues[i]);
        };
        break;
      case SettingType.iso:
        currentValue = iso.clamp(minISO, maxISO);
        minValue = minISO;
        maxValue = maxISO;
        label = 'ISO ${iso.toInt()}';
        divisions = 50;
        callback = onISOChanged;
        break;
      case SettingType.ev:
        currentValue = exposureBias.clamp(-4.0, 4.0);
        minValue = -4.0;
        maxValue = 4.0;
        label =
            '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)} EV';
        divisions = 32;
        callback = onExposureBiasChanged;
        break;
      case SettingType.focus:
        currentValue = focus.clamp(0.0, 1.0);
        minValue = 0.0;
        maxValue = 1.0;
        label = 'FOCUS ${focus.toStringAsFixed(2)}';
        divisions = 100;
        callback = onFocusChanged;
        break;
      case SettingType.zoom:
        currentValue = zoom.clamp(1.0, maxZoom);
        minValue = 1.0;
        maxValue = maxZoom;
        label = '${zoom.toStringAsFixed(1)}x';
        divisions = ((maxZoom - 1.0) * 10).round().clamp(1, 100);
        callback = onZoomChanged;
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.78),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withOpacity(0.5), width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rotate only the value label. Rotating the interactive ruler also
          // rotates its hit-test axis, which makes landscape gestures confusing.
          SizedBox(
            height: 26,
            child: Center(
              child: _rotate(
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: 62,
            child: _MovingRuler(
              value: currentValue,
              min: minValue,
              max: maxValue,
              divisions: divisions,
              onChanged: callback,
            ),
          ),
        ],
      ),
    );
  }

  int _shutterIndex(double seconds) {
    int closestIdx = 0;
    double closestDiff = double.infinity;
    for (int i = 0; i < shutterSpeedValues.length; i++) {
      final diff = (shutterSpeedValues[i] - seconds).abs();
      if (diff < closestDiff) {
        closestDiff = diff;
        closestIdx = i;
      }
    }
    return closestIdx;
  }

  double _secondsFromLabel(String label) {
    if (label.contains('"')) {
      return double.tryParse(label.replaceAll('"', '')) ?? 1;
    } else if (label.contains('/')) {
      final parts = label.split('/');
      if (parts.length == 2) {
        return 1 / (double.tryParse(parts[1]) ?? 60);
      }
    }
    return 1 / 60;
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
              color: Colors.black26,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: isCapturing ? null : onCapture,
            child: Container(
              width: 75,
              height: 75,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
                color: isCapturing ? Colors.white38 : Colors.white,
              ),
              child: Center(
                child: isCapturing
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Container(
                        width: 63,
                        height: 63,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ),
          const Spacer(),
          const SizedBox(width: 50, height: 50),
        ],
      ),
    );
  }
}

// === CAMERA-STYLE MOVING RULER ===
// The amber marker stays fixed while the scale moves underneath it.
class _MovingRuler extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _MovingRuler({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  State<_MovingRuler> createState() => _MovingRulerState();
}

class _MovingRulerState extends State<_MovingRuler> {
  static const double _pixelsPerStep = 14;

  late double _displayValue;
  double _dragStartValue = 0;
  double _dragDistance = 0;
  double? _lastReportedValue;
  bool _isDragging = false;

  double get _step {
    if (widget.divisions <= 0 || widget.max <= widget.min) return 1;
    return (widget.max - widget.min) / widget.divisions;
  }

  @override
  void initState() {
    super.initState();
    _displayValue = widget.value.clamp(widget.min, widget.max).toDouble();
  }

  @override
  void didUpdateWidget(covariant _MovingRuler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isDragging && oldWidget.value != widget.value) {
      _displayValue = widget.value.clamp(widget.min, widget.max).toDouble();
    }
  }

  void _startDrag(DragStartDetails details) {
    _isDragging = true;
    _dragDistance = 0;
    _dragStartValue = widget.value.clamp(widget.min, widget.max).toDouble();
    _displayValue = _dragStartValue;
    _lastReportedValue = widget.value;
  }

  void _updateDrag(DragUpdateDetails details) {
    _dragDistance += details.delta.dx;

    // Moving the scale to the left selects a higher value.
    final rawSteps = -_dragDistance / _pixelsPerStep;
    final rawValue = (_dragStartValue + rawSteps * _step)
        .clamp(widget.min, widget.max)
        .toDouble();

    setState(() => _displayValue = rawValue);

    final divisionIndex = ((rawValue - widget.min) / _step).round();
    final snappedValue = (widget.min + divisionIndex * _step)
        .clamp(widget.min, widget.max)
        .toDouble();

    // Call the native camera only when the selected tick changes.
    if (_lastReportedValue == null ||
        (snappedValue - _lastReportedValue!).abs() > 0.000001) {
      _lastReportedValue = snappedValue;
      widget.onChanged(snappedValue);
    }
  }

  void _finishDrag() {
    if (!_isDragging) return;
    _isDragging = false;

    final finalValue = (_lastReportedValue ?? widget.value)
        .clamp(widget.min, widget.max)
        .toDouble();

    setState(() {
      _displayValue = finalValue;
      _dragDistance = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _startDrag,
      onHorizontalDragUpdate: _updateDrag,
      onHorizontalDragEnd: (_) => _finishDrag(),
      onHorizontalDragCancel: _finishDrag,
      child: CustomPaint(
        size: Size.infinite,
        painter: _MovingRulerPainter(
          displayValue: _displayValue,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          pixelsPerStep: _pixelsPerStep,
        ),
      ),
    );
  }
}

class _MovingRulerPainter extends CustomPainter {
  final double displayValue;
  final double min;
  final double max;
  final int divisions;
  final double pixelsPerStep;

  const _MovingRulerPainter({
    required this.displayValue,
    required this.min,
    required this.max,
    required this.divisions,
    required this.pixelsPerStep,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (divisions <= 0 || max <= min) return;

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final step = (max - min) / divisions;
    final currentIndex = (displayValue - min) / step;
    final visibleSteps = (size.width / pixelsPerStep / 2).ceil() + 2;
    final firstIndex = math.max(0, currentIndex.floor() - visibleSteps);
    final lastIndex = math.min(divisions, currentIndex.ceil() + visibleSteps);

    final minorPaint = Paint()
      ..color = Colors.white.withOpacity(0.38)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    final mediumPaint = Paint()
      ..color = Colors.white.withOpacity(0.62)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final majorPaint = Paint()
      ..color = Colors.white.withOpacity(0.88)
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    for (int index = firstIndex; index <= lastIndex; index++) {
      final x = centerX + (index - currentIndex) * pixelsPerStep;
      if (x < -pixelsPerStep || x > size.width + pixelsPerStep) continue;

      final isMajor = index % 5 == 0;
      final isMedium = !isMajor && index % 2 == 0;
      final tickHeight = isMajor ? 26.0 : (isMedium ? 18.0 : 11.0);
      final paint = isMajor
          ? majorPaint
          : (isMedium ? mediumPaint : minorPaint);

      canvas.drawLine(
        Offset(x, centerY - tickHeight / 2),
        Offset(x, centerY + tickHeight / 2),
        paint,
      );
    }

    // Fade both edges so the fixed center selection is emphasized.
    final edgeFadePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.black.withOpacity(0.75),
          Colors.transparent,
          Colors.transparent,
          Colors.black.withOpacity(0.75),
        ],
        stops: const [0, 0.18, 0.82, 1],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      edgeFadePaint,
    );

    final indicatorPaint = Paint()
      ..color = Colors.amber
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(centerX, 5),
      Offset(centerX, size.height - 5),
      indicatorPaint,
    );

    final triangle = Path()
      ..moveTo(centerX - 5, 2)
      ..lineTo(centerX + 5, 2)
      ..lineTo(centerX, 9)
      ..close();
    canvas.drawPath(triangle, Paint()..color = Colors.amber);
  }

  @override
  bool shouldRepaint(covariant _MovingRulerPainter oldDelegate) {
    return oldDelegate.displayValue != displayValue ||
        oldDelegate.min != min ||
        oldDelegate.max != max ||
        oldDelegate.divisions != divisions;
  }
}

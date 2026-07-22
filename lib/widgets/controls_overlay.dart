import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Setting types for the active dial
enum SettingType { none, shutter, iso, ev, focus, zoom }

class ControlsOverlay extends StatelessWidget {
  final double iso, minISO, maxISO, exposureBias, zoom, maxZoom, focus;
  final String shutterSpeed, aspectRatio, flashMode;
  final List<double> shutterSpeedValues;
  final List<String> aspectRatios;
  final bool isHDREnabled, isRawEnabled, isHdrPlusEnabled, isCapturing;
  final int uiOrientation;
  final SettingType activeDial;
  final Function(double) onISOChanged, onShutterSpeedChanged, onExposureBiasChanged, onZoomChanged, onFocusChanged;
  final Function(String) onAspectRatioChanged, onFlashModeChanged;
  final Function(SettingType) onSelectDial;
  final VoidCallback onCapture, onToggleHDR, onToggleRAW, onToggleHdrPlus;

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
    required this.isHdrPlusEnabled,
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
    required this.onToggleHdrPlus,
  });

  double get _rotationAngle {
    switch (uiOrientation) {
      case 1: return -math.pi / 2;
      case 2: return math.pi;
      case 3: return math.pi / 2;
      default: return 0;
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
          if (activeDial != SettingType.none)
            _buildRulerDial(),
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
            onTap: () {
              final next = flashMode == 'off' ? 'on' : flashMode == 'on' ? 'auto' : 'off';
              onFlashModeChanged(next);
            },
            child: _rotate(_pill(
              icon: flashMode == 'off'
                  ? Icons.flash_off
                  : flashMode == 'on'
                      ? Icons.flash_on
                      : Icons.flash_auto,
              label: flashMode.toUpperCase(),
              color: flashMode == 'off' ? Colors.grey : Colors.amber,
            )),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onToggleHDR,
            child: _rotate(_pill(
              label: 'HDR',
              color: isHDREnabled ? Colors.amber : Colors.grey,
            )),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onToggleHdrPlus,
            child: _rotate(_pill(
              icon: Icons.hdr_on,
              label: 'HDR+',
              color: isHdrPlusEnabled ? Colors.greenAccent : Colors.grey,
            )),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onToggleRAW,
            child: _rotate(_pill(
              label: 'RAW',
              color: isRawEnabled ? Colors.amber : Colors.grey,
            )),
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
          Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
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
              child: _rotate(Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.amber.withOpacity(0.3) : Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: isSelected ? Colors.amber : Colors.white24, width: 1),
                ),
                child: Text(ratio,
                    style: TextStyle(
                      color: isSelected ? Colors.amber : Colors.white70,
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    )),
              )),
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
            value: shutterSpeed,
          ),
          _pickerButton(
            type: SettingType.iso,
            label: 'ISO',
            value: iso.toInt().toString(),
          ),
          _pickerButton(
            type: SettingType.ev,
            label: 'EV',
            value: '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)}',
          ),
          _pickerButton(
            type: SettingType.focus,
            label: 'FOCUS',
            value: focus.toStringAsFixed(2),
          ),
          _pickerButton(
            type: SettingType.zoom,
            label: 'ZOOM',
            value: '${zoom.toStringAsFixed(1)}x',
          ),
        ],
      ),
    );
  }

  Widget _pickerButton({
    required SettingType type,
    required String label,
    required String value,
  }) {
    final isActive = activeDial == type;
    return GestureDetector(
      onTap: () {
        // Tap toggle: if same active, close; else switch
        onSelectDial(isActive ? SettingType.none : type);
      },
      behavior: HitTestBehavior.opaque,
      child: _rotate(Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? Colors.amber.withOpacity(0.25) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? Colors.amber : Colors.transparent,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value,
                style: TextStyle(
                  color: isActive ? Colors.amber : Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                )),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                  color: isActive ? Colors.amber : Colors.grey,
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
      )),
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
        currentValue = _shutterIndex(_secondsFromLabel(shutterSpeed)).toDouble();
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
        label = '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)} EV';
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
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.withOpacity(0.5), width: 1),
      ),
      child: _rotate(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Current value label
          Text(
            label,
            style: const TextStyle(
              color: Colors.amber,
              fontSize: 16,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          // Ruler with tick marks
          SizedBox(
            height: 44,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomPaint(
                  size: Size(constraints.maxWidth, 44),
                  painter: _RulerPainter(
                    value: currentValue,
                    min: minValue,
                    max: maxValue,
                  ),
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.transparent,
                      inactiveTrackColor: Colors.transparent,
                      thumbColor: Colors.transparent,
                      overlayColor: Colors.transparent,
                      trackHeight: 40,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 20),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 25),
                    ),
                    child: Slider(
                      value: currentValue,
                      min: minValue,
                      max: maxValue,
                      divisions: divisions,
                      onChanged: callback,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      )),
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
                border: Border.all(
                  color: isHdrPlusEnabled ? Colors.greenAccent : Colors.white,
                  width: 4,
                ),
                color: isCapturing ? Colors.white38 : Colors.white,
              ),
              child: Center(
                child: isCapturing
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Container(
                        width: 63,
                        height: 63,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isHdrPlusEnabled ? Colors.greenAccent : Colors.white,
                        )),
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

// === CUSTOM PAINTER FOR RULER TICKS ===
class _RulerPainter extends CustomPainter {
  final double value;
  final double min;
  final double max;

  _RulerPainter({
    required this.value,
    required this.min,
    required this.max,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final centerY = h / 2;

    // Draw tick marks — 20 minor ticks + 5 major ticks across the width
    final tickPaint = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..strokeWidth = 1;

    final majorTickPaint = Paint()
      ..color = Colors.white.withOpacity(0.7)
      ..strokeWidth = 1.5;

    const numMinorTicks = 20;
    const numMajorTicks = 5;

    for (int i = 0; i <= numMinorTicks; i++) {
      final x = (w / numMinorTicks) * i;
      // Every 4th tick = major
      final isMajor = i % (numMinorTicks ~/ numMajorTicks) == 0;
      final tickHeight = isMajor ? 12.0 : 6.0;
      canvas.drawLine(
        Offset(x, centerY - tickHeight / 2),
        Offset(x, centerY + tickHeight / 2),
        isMajor ? majorTickPaint : tickPaint,
      );
    }

    // Draw center vertical indicator (amber)
    final normalized = (value - min) / (max - min);
    final thumbX = normalized * w;

    final indicatorPaint = Paint()
      ..color = Colors.amber
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(thumbX, centerY - 18),
      Offset(thumbX, centerY + 18),
      indicatorPaint,
    );

    // Draw small circle sa taas ng indicator
    final circlePaint = Paint()
      ..color = Colors.amber
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(thumbX, centerY - 20), 4, circlePaint);
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) {
    return oldDelegate.value != value ||
        oldDelegate.min != min ||
        oldDelegate.max != max;
  }
}
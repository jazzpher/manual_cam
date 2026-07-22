import 'dart:math' as math;
import 'package:flutter/material.dart';

class ControlsOverlay extends StatelessWidget {
  final double iso, minISO, maxISO, exposureBias, zoom, maxZoom, focus;
  final String shutterSpeed, aspectRatio, flashMode;
  final List<double> shutterSpeedValues;
  final List<String> aspectRatios;
  final bool isHDREnabled, isRawEnabled, isHdrPlusEnabled, isCapturing;
  final int uiOrientation;
  final Function(double) onISOChanged, onShutterSpeedChanged, onExposureBiasChanged, onZoomChanged, onFocusChanged;
  final Function(String) onAspectRatioChanged, onFlashModeChanged;
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
    required this.onISOChanged,
    required this.onShutterSpeedChanged,
    required this.onExposureBiasChanged,
    required this.onZoomChanged,
    required this.onFocusChanged,
    required this.onAspectRatioChanged,
    required this.onFlashModeChanged,
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

  // Find nearest shutter value sa slider position
  double _shutterSecondsFromIndex(double index) {
    final i = index.round().clamp(0, shutterSpeedValues.length - 1);
    return shutterSpeedValues[i];
  }

  double _shutterIndexFromValue(double seconds) {
    // Find closest match
    int closestIdx = 0;
    double closestDiff = double.infinity;
    for (int i = 0; i < shutterSpeedValues.length; i++) {
      final diff = (shutterSpeedValues[i] - seconds).abs();
      if (diff < closestDiff) {
        closestDiff = diff;
        closestIdx = i;
      }
    }
    return closestIdx.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(),
          const Spacer(),
          _buildAspectRatioSelector(),
          const SizedBox(height: 4),
          _buildInlineSliders(context),
          const SizedBox(height: 8),
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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
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

  // === INLINE SLIDERS (Halide-style, always visible) ===
  Widget _buildInlineSliders(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildInlineSlider(
            context: context,
            label: 'SHUTTER',
            valueText: shutterSpeed,
            value: _shutterIndexFromValue(_secondsFromLabel(shutterSpeed)),
            min: 0,
            max: (shutterSpeedValues.length - 1).toDouble(),
            divisions: shutterSpeedValues.length - 1,
            onChanged: (idx) => onShutterSpeedChanged(_shutterSecondsFromIndex(idx)),
          ),
          _buildInlineSlider(
            context: context,
            label: 'ISO',
            valueText: iso.toInt().toString(),
            value: iso.clamp(minISO, maxISO),
            min: minISO,
            max: maxISO,
            divisions: 50,
            onChanged: onISOChanged,
          ),
          _buildInlineSlider(
            context: context,
            label: 'EV',
            valueText: '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)}',
            value: exposureBias.clamp(-4.0, 4.0),
            min: -4.0,
            max: 4.0,
            divisions: 32,
            onChanged: onExposureBiasChanged,
          ),
          _buildInlineSlider(
            context: context,
            label: 'FOCUS',
            valueText: focus.toStringAsFixed(2),
            value: focus.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 100,
            onChanged: onFocusChanged,
          ),
          _buildInlineSlider(
            context: context,
            label: 'ZOOM',
            valueText: '${zoom.toStringAsFixed(1)}x',
            value: zoom.clamp(1.0, maxZoom),
            min: 1.0,
            max: maxZoom,
            divisions: ((maxZoom - 1.0) * 10).round().clamp(1, 100),
            onChanged: onZoomChanged,
          ),
        ],
      ),
    );
  }

  // Reverse lookup: convert shutter label back to seconds
  double _secondsFromLabel(String label) {
    if (label.contains('"')) {
      // e.g. "2\""
      final n = double.tryParse(label.replaceAll('"', '')) ?? 1;
      return n;
    } else if (label.contains('/')) {
      // e.g. "1/60"
      final parts = label.split('/');
      if (parts.length == 2) {
        final denom = double.tryParse(parts[1]) ?? 60;
        return 1 / denom;
      }
    }
    return 1 / 60; // fallback
  }

  Widget _buildInlineSlider({
    required BuildContext context,
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required Function(double) onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          // Label
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.left,
            ),
          ),
          // Slider
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: Colors.amber,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.amber,
                overlayColor: Colors.amber.withOpacity(0.2),
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          // Value display
          SizedBox(
            width: 55,
            child: Text(
              valueText,
              style: const TextStyle(
                color: Colors.amber,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
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
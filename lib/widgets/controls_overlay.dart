import 'dart:math' as math;
import 'package:flutter/material.dart';

class ControlsOverlay extends StatelessWidget {
  final double iso, minISO, maxISO, exposureBias, zoom, maxZoom, focus;
  final String shutterSpeed, aspectRatio, flashMode;
  final List<double> shutterSpeedValues;
  final List<String> aspectRatios;
  final bool isHDREnabled, isRawEnabled, isCineEnabled, isCapturing;
  final int uiOrientation; // 0=portrait, 1=landscapeRight, 2=upsideDown, 3=landscapeLeft
  final bool showISOSlider, showEVSlider, showShutterPicker, showFocusSlider, showZoomSlider;
  final Function(double) onISOChanged, onShutterSpeedChanged, onExposureBiasChanged, onZoomChanged, onFocusChanged;
  final Function(String) onAspectRatioChanged, onFlashModeChanged;
  final VoidCallback onCapture, onToggleHDR, onToggleRAW, onToggleCine;
  final VoidCallback onToggleISOSlider, onToggleEVSlider, onToggleShutterPicker, onToggleFocusSlider, onToggleZoomSlider;
  final VoidCallback onCloseAllPopups;

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
    required this.isCineEnabled,
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
    required this.onToggleCine,
    required this.showISOSlider,
    required this.onToggleISOSlider,
    required this.showEVSlider,
    required this.onToggleEVSlider,
    required this.showShutterPicker,
    required this.onToggleShutterPicker,
    required this.showFocusSlider,
    required this.onToggleFocusSlider,
    required this.showZoomSlider,
    required this.onToggleZoomSlider,
    required this.onCloseAllPopups,
  });

  bool get _anyPopupOpen =>
      showISOSlider || showEVSlider || showShutterPicker || showFocusSlider || showZoomSlider;

  /// Convert orientation code to rotation angle (radians).
  /// Portrait UI = 0°, so:
  /// - Landscape right (phone rotated CW) → icons rotate +90° (CCW visually)
  /// - Upside down → 180°
  /// - Landscape left → -90°
  double get _rotationAngle {
    switch (uiOrientation) {
      case 1: return -math.pi / 2;   // landscape right → rotate icons CCW
      case 2: return math.pi;         // upside down
      case 3: return math.pi / 2;    // landscape left → rotate icons CW
      default: return 0;              // portrait
    }
  }

  /// Wrap any widget sa smooth rotation animation
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
    return Stack(
      children: [
        if (_anyPopupOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: onCloseAllPopups,
              child: Container(color: Colors.transparent),
            ),
          ),

        SafeArea(
          child: Column(
            children: [
              _buildTopBar(),
              const Spacer(),
              _buildSettingsDisplay(),
              const SizedBox(height: 8),
              _buildBottomControls(),
              const SizedBox(height: 16),
            ],
          ),
        ),

        if (showISOSlider) _buildISOSliderPopup(context),
        if (showEVSlider) _buildEVSliderPopup(context),
        if (showShutterPicker) _buildShutterPickerPopup(context),
        if (showFocusSlider) _buildFocusSliderPopup(context),
        if (showZoomSlider) _buildZoomSliderPopup(context),
      ],
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
            onTap: onToggleCine,
            child: _rotate(_pill(
              icon: Icons.movie_filter,
              label: 'CINE',
              color: isCineEnabled ? Colors.deepOrangeAccent : Colors.grey,
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

  Widget _buildSettingsDisplay() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildSettingButton(label: 'SHUTTER', value: shutterSpeed, onTap: onToggleShutterPicker),
              const SizedBox(width: 16),
              _buildSettingButton(label: 'ISO', value: '${iso.toInt()}', onTap: onToggleISOSlider),
              const SizedBox(width: 16),
              _buildSettingButton(label: 'EV', value: exposureBias.toStringAsFixed(1), onTap: onToggleEVSlider),
              const SizedBox(width: 16),
              _buildSettingButton(label: 'FOCUS', value: focus.toStringAsFixed(2), onTap: onToggleFocusSlider),
              const SizedBox(width: 16),
              _buildSettingButton(label: 'ZOOM', value: '${zoom.toStringAsFixed(1)}x', onTap: onToggleZoomSlider),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: aspectRatios.map((ratio) {
              final isSelected = ratio == aspectRatio;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: GestureDetector(
                  onTap: () => onAspectRatioChanged(ratio),
                  child: _rotate(Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.amber.withOpacity(0.3) : Colors.black38,
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
        ],
      ),
    );
  }

  Widget _buildSettingButton({required String label, required String value, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: _rotate(Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                )),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.w500)),
          ],
        )),
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
                  color: isCineEnabled ? Colors.deepOrangeAccent : Colors.white,
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
                          color: isCineEnabled ? Colors.deepOrangeAccent : Colors.white,
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

  Widget _popupCard({
    required String title,
    required VoidCallback onClose,
    required Widget child,
  }) {
    return Positioned(
      bottom: 220,
      left: 12,
      right: 12,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () {},
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.92),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: onClose,
                        borderRadius: BorderRadius.circular(22),
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white12,
                            ),
                            child: const Icon(Icons.close, color: Colors.white, size: 18),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slider({
    required BuildContext context,
    required double value,
    required double min,
    required double max,
    required String display,
    required Function(double) onChanged,
    int? divisions,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.amber,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.amber,
            overlayColor: Colors.amber.withOpacity(0.2),
            trackHeight: 4,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        Text(display,
            style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 16)),
      ],
    );
  }

  Widget _buildISOSliderPopup(BuildContext context) {
    return _popupCard(
      title: 'ISO',
      onClose: onToggleISOSlider,
      child: _slider(
        context: context,
        value: iso,
        min: minISO,
        max: maxISO,
        display: 'ISO ${iso.toInt()}',
        divisions: 50,
        onChanged: onISOChanged,
      ),
    );
  }

  Widget _buildEVSliderPopup(BuildContext context) {
    return _popupCard(
      title: 'Exposure Bias (EV)',
      onClose: onToggleEVSlider,
      child: _slider(
        context: context,
        value: exposureBias,
        min: -4.0,
        max: 4.0,
        display: '${exposureBias >= 0 ? '+' : ''}${exposureBias.toStringAsFixed(1)} EV',
        divisions: 32,
        onChanged: onExposureBiasChanged,
      ),
    );
  }

  Widget _buildFocusSliderPopup(BuildContext context) {
    return _popupCard(
      title: 'Manual Focus  (0 = infinity, 1 = macro)',
      onClose: onToggleFocusSlider,
      child: _slider(
        context: context,
        value: focus,
        min: 0.0,
        max: 1.0,
        display: focus.toStringAsFixed(2),
        divisions: 100,
        onChanged: onFocusChanged,
      ),
    );
  }

  Widget _buildZoomSliderPopup(BuildContext context) {
    return _popupCard(
      title: 'Zoom',
      onClose: onToggleZoomSlider,
      child: _slider(
        context: context,
        value: zoom,
        min: 1.0,
        max: maxZoom,
        display: '${zoom.toStringAsFixed(1)}x',
        divisions: ((maxZoom - 1.0) * 10).round().clamp(1, 100),
        onChanged: onZoomChanged,
      ),
    );
  }

  Widget _buildShutterPickerPopup(BuildContext context) {
    return _popupCard(
      title: 'Shutter Speed',
      onClose: onToggleShutterPicker,
      child: SizedBox(
        height: 60,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: shutterSpeedValues.length,
          itemBuilder: (context, i) {
            final val = shutterSpeedValues[i];
            final label = val >= 1 ? '${val.toInt()}"' : '1/${(1 / val).round()}';
            final selected = label == shutterSpeed;
            return GestureDetector(
              onTap: () => onShutterSpeedChanged(val),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? Colors.amber.withOpacity(0.3) : Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: selected ? Colors.amber : Colors.white24),
                ),
                child: Center(
                  child: Text(label,
                      style: TextStyle(
                        color: selected ? Colors.amber : Colors.white70,
                        fontWeight: FontWeight.bold,
                      )),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
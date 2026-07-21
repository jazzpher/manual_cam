import 'package:flutter/material.dart';

class ControlsOverlay extends StatelessWidget {
  final double iso, minISO, maxISO, exposureBias, zoom;
  final String shutterSpeed, aspectRatio;
  final List<double> shutterSpeedValues;
  final List<String> aspectRatios;
  final bool isRawEnabled, isCapturing, showISOSlider, showEVSlider;
  final Function(double) onISOChanged, onShutterSpeedChanged, onExposureBiasChanged, onZoomChanged;
  final Function(String) onAspectRatioChanged;
  final VoidCallback onCapture;
  final Function(bool) onToggleRaw;
  final VoidCallback onToggleISOSlider, onToggleEVSlider;

  const ControlsOverlay({
    super.key,
    required this.iso, required this.minISO, required this.maxISO,
    required this.shutterSpeed, required this.shutterSpeedValues,
    required this.exposureBias, required this.zoom,
    required this.aspectRatio, required this.aspectRatios,
    required this.isRawEnabled, required this.isCapturing,
    required this.onISOChanged, required this.onShutterSpeedChanged,
    required this.onExposureBiasChanged, required this.onZoomChanged,
    required this.onAspectRatioChanged, required this.onCapture,
    required this.onToggleRaw, required this.showISOSlider, required this.onToggleISOSlider,
    required this.showEVSlider, required this.onToggleEVSlider,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(),
          const Spacer(),
          _buildSettingsDisplay(),
          const SizedBox(height: 8),
          _buildBottomControls(),
          const SizedBox(height: 16),
          if (showISOSlider) _buildISOSliderPopup(context),
          if (showEVSlider) _buildEVSliderPopup(context),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: isRawEnabled ? Colors.amber : Colors.grey, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 8, height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: isRawEnabled ? Colors.amber : Colors.grey)),
                const SizedBox(width: 4),
                Text('RAW', style: TextStyle(color: isRawEnabled ? Colors.amber : Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => onToggleRaw(!isRawEnabled),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: isRawEnabled ? Colors.orange : Colors.grey, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isRawEnabled ? 'RAW (sim)' : 'JPEG',
                    style: TextStyle(
                      color: isRawEnabled ? Colors.orange : Colors.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
              _buildSettingButton(label: 'SHUTTER', value: shutterSpeed, onTap: () {}),
              const SizedBox(width: 20),
              _buildSettingButton(label: 'ISO', value: '${iso.toInt()}', onTap: onToggleISOSlider),
              const SizedBox(width: 20),
              _buildSettingButton(label: 'EV', value: exposureBias.toStringAsFixed(1), onTap: onToggleEVSlider),
              const SizedBox(width: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                child: Text('${zoom.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
              ),
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
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isSelected ? Colors.amber.withOpacity(0.3) : Colors.black38,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: isSelected ? Colors.amber : Colors.white24, width: 1),
                    ),
                    child: Text(ratio, style: TextStyle(color: isSelected ? Colors.amber : Colors.white70, fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                  ),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Row(
        children: [
          Container(width: 50, height: 50,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24), color: Colors.black26)),
          const Spacer(),
          GestureDetector(
            onTap: isCapturing ? null : onCapture,
            child: Container(
              width: 75, height: 75,
              decoration: BoxDecoration(
                shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4),
                color: isCapturing ? Colors.white38 : Colors.white,
              ),
              child: Center(
                child: isCapturing
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Container(width: 63, height: 63, decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white)),
              ),
            ),
          ),
          const Spacer(),
          const Opacity(opacity: 0, child: Icon(Icons.flip_camera_ios, color: Colors.white, size: 28)),
        ],
      ),
    );
  }

  Widget _buildISOSliderPopup(BuildContext context) {
    return Positioned(
      bottom: 100, left: 16, right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white12)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('ISO Control', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                GestureDetector(onTap: onToggleISOSlider, child: const Icon(Icons.close, color: Colors.white54, size: 20)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Text('${minISO.toInt()}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                Expanded(
                  child: SliderTheme(data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.amber, inactiveTrackColor: Colors.white24, thumbColor: Colors.amber,
                    overlayColor: Colors.amber.withOpacity(0.2),
                  ), child: Slider(value: iso.clamp(minISO, maxISO), min: minISO, max: maxISO, divisions: 50, onChanged: onISOChanged)),
                ),
                Text('${maxISO.toInt()}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ]),
              Text('ISO ${iso.toInt()}', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEVSliderPopup(BuildContext context) {
    return Positioned(
      bottom: 100, left: 16, right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white12)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Exposure Compensation', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                GestureDetector(onTap: onToggleEVSlider, child: const Icon(Icons.close, color: Colors.white54, size: 20)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                const Text('-4', style: TextStyle(color: Colors.grey, fontSize: 11)),
                Expanded(
                  child: SliderTheme(data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.amber, inactiveTrackColor: Colors.white24, thumbColor: Colors.amber,
                    overlayColor: Colors.amber.withOpacity(0.2),
                  ), child: Slider(value: exposureBias, min: -4.0, max: 4.0, divisions: 16, onChanged: onExposureBiasChanged)),
                ),
                const Text('+4', style: TextStyle(color: Colors.grey, fontSize: 11)),
              ]),
              GestureDetector(
                onTap: () => onExposureBiasChanged(0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(12)),
                  child: Text('Reset (${exposureBias.toStringAsFixed(1)} EV)', style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

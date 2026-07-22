import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native iOS AVFoundation camera preview.
class NativeCameraPreview extends StatelessWidget {
  final String aspectRatio; // "4:3" | "16:9" | "1:1" | "3:2"
  final void Function(double x, double y)? onTap;
  final double softwareZoom;

  const NativeCameraPreview({
    super.key,
    this.aspectRatio = '4:3',
    this.onTap,
    this.softwareZoom = 1.0,
  });

  double _aspectValue(String label) {
    switch (label) {
      case '16:9':
        return 9 / 16;
      case '1:1':
        return 1.0;
      case '3:2':
        return 2 / 3;
      case '4:3':
      default:
        return 3 / 4;
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _aspectValue(aspectRatio);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Available screen space
        final availableW = constraints.maxWidth;
        final availableH = constraints.maxHeight;

        // Compute preview box na tumutugma sa target aspect ratio
        // Try width-constrained muna: kung sobra ang height, i-height-constrain natin
        double previewW = availableW;
        double previewH = previewW / target;

        if (previewH > availableH) {
          previewH = availableH;
          previewW = previewH * target;
        }

        return Container(
          color: Colors.black,
          // === PROPER CENTERING via Center widget (fixes 16:9 na naka-taas issue) ===
          child: Center(
            child: SizedBox(
              width: previewW,
              height: previewH,
              child: ClipRect(
                child: GestureDetector(
                  onTapDown: (details) {
                    if (onTap != null) {
                      final rawX = details.localPosition.dx / previewW;
                      final rawY = details.localPosition.dy / previewH;
                      final visibleFraction = 1.0 / softwareZoom;
                      final offsetFraction = (1.0 - visibleFraction) / 2.0;
                      final cameraX = offsetFraction + (rawX * visibleFraction);
                      final cameraY = offsetFraction + (rawY * visibleFraction);
                      onTap!(cameraX.clamp(0.0, 1.0), cameraY.clamp(0.0, 1.0));
                    }
                  },
                  child: Transform.scale(
                    scale: softwareZoom,
                    alignment: Alignment.center,
                    child: const UiKitView(
                      viewType: 'native_camera_preview',
                      creationParams: null,
                      creationParamsCodec: StandardMessageCodec(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
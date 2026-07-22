import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native iOS AVFoundation camera preview.
/// Automatic na tama yung aspect ratio via videoGravity = resizeAspect.
/// May software zoom din para sa Halide-style RAW zoom (via Transform.scale).
class NativeCameraPreview extends StatelessWidget {
  final String aspectRatio; // "4:3" | "16:9" | "1:1" | "3:2"
  final void Function(double x, double y)? onTap;
  final double softwareZoom; // 1.0 = no zoom; >1.0 = center-crop zoom

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
        double w = constraints.maxWidth;
        double h = w / target;
        if (h > constraints.maxHeight) {
          h = constraints.maxHeight;
          w = h * target;
        }

        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: SizedBox(
            width: w,
            height: h,
            child: ClipRect(
              child: GestureDetector(
                onTapDown: (details) {
                  if (onTap != null) {
                    // Note: kapag naka-software zoom, ang tap point ay adjust based sa crop
                    final rawX = details.localPosition.dx / w;
                    final rawY = details.localPosition.dy / h;

                    // Convert visible coord to camera-native coord
                    // Kapag zoomed 2x, ang visible area ay 50% ng full sensor sa gitna
                    // Kaya kailangan i-map back sa full sensor coordinates
                    final visibleFraction = 1.0 / softwareZoom;
                    final offsetFraction = (1.0 - visibleFraction) / 2.0;

                    final cameraX = offsetFraction + (rawX * visibleFraction);
                    final cameraY = offsetFraction + (rawY * visibleFraction);

                    onTap!(cameraX.clamp(0.0, 1.0), cameraY.clamp(0.0, 1.0));
                  }
                },
                // Halide-style software zoom: mag-scale ng preview at i-clip
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
        );
      },
    );
  }
}
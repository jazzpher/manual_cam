import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native iOS AVFoundation camera preview.
/// Automatic na tama yung aspect ratio at pina-preserve ng videoGravity = resizeAspect.
class NativeCameraPreview extends StatelessWidget {
  final String aspectRatio; // "4:3" | "16:9" | "1:1" | "3:2"
  final void Function(double x, double y)? onTap;

  const NativeCameraPreview({
    super.key,
    this.aspectRatio = '4:3',
    this.onTap,
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
                    final localX = details.localPosition.dx / w;
                    final localY = details.localPosition.dy / h;
                    onTap!(localX.clamp(0.0, 1.0), localY.clamp(0.0, 1.0));
                  }
                },
                child: const UiKitView(
                  viewType: 'native_camera_preview',
                  creationParams: null,
                  creationParamsCodec: StandardMessageCodec(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

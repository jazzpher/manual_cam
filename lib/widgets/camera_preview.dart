import 'package:flutter/material.dart';
import '../services/manual_camera.dart';

class CameraPreview extends StatelessWidget {
  final ManualCamera camera;
  final String aspectRatio; // "4:3" | "16:9" | "1:1" | "3:2"

  const CameraPreview({
    super.key,
    required this.camera,
    this.aspectRatio = '4:3',
  });

  /// Convert aspect ratio label to width/height (portrait).
  double _aspectToRatio(String label) {
    switch (label) {
      case '16:9':
        return 9 / 16; // portrait: mas tall (0.5625)
      case '1:1':
        return 1.0;
      case '3:2':
        return 2 / 3; // portrait (0.667)
      case '4:3':
      default:
        return 3 / 4; // portrait (0.75) — native ng iPhone camera
    }
  }

  @override
  Widget build(BuildContext context) {
    final double targetAspect = _aspectToRatio(aspectRatio);

    if (camera.controller == null || !camera.controller!.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.amber),
        ),
      );
    }

    // Native aspect ratio ng camera sa portrait (~ 0.75 for 4:3)
    final double nativeAspect = camera.nativePortraitAspectRatio ?? 0.75;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Compute preview box size na fit sa screen with target aspect ratio.
        double previewW = constraints.maxWidth;
        double previewH = previewW / targetAspect;

        if (previewH > constraints.maxHeight) {
          previewH = constraints.maxHeight;
          previewW = previewH * targetAspect;
        }

        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: SizedBox(
            width: previewW,
            height: previewH,
            child: ClipRect(
              child: OverflowBox(
                // Native camera aspect ratio (usually 4:3 = 0.75 portrait)
                // Ilalagay natin yung camera preview sa native aspect nito,
                // tapos ang ClipRect na wrapper ang mag-cro-crop sa target aspect.
                alignment: Alignment.center,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: FittedBox(
                  fit: targetAspect > nativeAspect
                      ? BoxFit.fitWidth // target is wider than native — fill width, crop top/bottom
                      : BoxFit.fitHeight, // target is taller than native — fill height, crop sides
                  child: SizedBox(
                    width: 1000, // arbitrary base, actual sized by FittedBox
                    height: 1000 / nativeAspect,
                    child: camera.getPreviewWidget(),
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

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), paint);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), paint);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), paint);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

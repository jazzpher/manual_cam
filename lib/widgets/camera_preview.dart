import 'package:flutter/material.dart';
import '../services/manual_camera.dart';

class CameraPreview extends StatelessWidget {
  final ManualCamera camera;
  const CameraPreview({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // If we have a real camera controller, use it
        if (camera.controller != null && camera.controller!.value.isInitialized) {
          return Stack(
            children: [
              // REAL CAMERA PREVIEW
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: camera.controller!.value.previewSize?.width ?? constraints.maxWidth,
                    height: camera.controller!.value.previewSize?.height ?? constraints.maxHeight,
                    child: camera.getPreviewWidget(),
                  ),
                ),
              ),

              // Overlay elements (grid, crosshair, watermark)
              _buildOverlay(constraints),
            ],
          );
        }

        // Fallback to simulated viewfinder (while initializing or on error)
        return Container(
          color: Colors.black,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _buildSimulatedViewfinder(constraints),
              _buildOverlay(constraints),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOverlay(BoxConstraints constraints) {
    return Stack(
      children: [
        // Grid lines
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: GridPainter(),
            ),
          ),
        ),

        // Center crosshair
        Center(
          child: Icon(
            Icons.center_focus_strong,
            size: 60,
            color: Colors.white.withOpacity(0.3),
          ),
        ),

        // "MANUAL CAM" watermark
        Positioned(
          bottom: 20,
          child: Text(
            'MANUAL CAM',
            style: TextStyle(
              color: Colors.white.withOpacity(0.15),
              fontSize: 24,
              fontWeight: FontWeight.bold,
              letterSpacing: 6,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSimulatedViewfinder(BoxConstraints constraints) {
    return CustomPaint(
      size: Size(constraints.maxWidth, constraints.maxHeight),
      painter: ViewfinderPainter(),
    );
  }
}

class ViewfinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        const Color(0xFF1a1a2e),
        const Color(0xFF16213e),
        const Color(0xFF0f3460),
      ],
    );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));

    final viewfinderRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: size.width * 0.85,
      height: size.height * 0.75,
    );

    final borderPaint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(viewfinderRect, borderPaint);

    final cornerPaint = Paint()
      ..color = Colors.white.withOpacity(0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final c = viewfinderRect;
    canvas.drawLine(c.topLeft, Offset(c.left + 30, c.top), cornerPaint);
    canvas.drawLine(c.topLeft, Offset(c.left, c.top + 30), cornerPaint);
    canvas.drawLine(c.topRight, Offset(c.right - 30, c.top), cornerPaint);
    canvas.drawLine(c.topRight, Offset(c.right, c.top + 30), cornerPaint);
    canvas.drawLine(c.bottomLeft, Offset(c.left + 30, c.bottom), cornerPaint);
    canvas.drawLine(c.bottomLeft, Offset(c.left, c.bottom - 30), cornerPaint);
    canvas.drawLine(c.bottomRight, Offset(c.right - 30, c.bottom), cornerPaint);
    canvas.drawLine(c.bottomRight, Offset(c.right, c.bottom - 30), cornerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.07)
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

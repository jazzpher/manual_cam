import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native iOS AVFoundation camera preview.
class NativeCameraPreview extends StatefulWidget {
  final String aspectRatio; // "4:3" | "16:9" | "1:1" | "3:2"
  final void Function(double x, double y)? onTap;
  final double softwareZoom;

  const NativeCameraPreview({
    super.key,
    this.aspectRatio = '4:3',
    this.onTap,
    this.softwareZoom = 1.0,
  });

  @override
  State<NativeCameraPreview> createState() => _NativeCameraPreviewState();
}

class _NativeCameraPreviewState extends State<NativeCameraPreview> {
  Offset? _reticlePoint;
  Timer? _reticleTimer;

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

  void _handleTapAt(Offset position, double width, double height) {
    final localPoint = Offset(
      position.dx.clamp(0.0, width),
      position.dy.clamp(0.0, height),
    );

    setState(() => _reticlePoint = localPoint);
    _reticleTimer?.cancel();
    _reticleTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _reticlePoint = null);
    });

    if (widget.onTap == null) return;

    final visibleX = localPoint.dx / width;
    final visibleY = localPoint.dy / height;

    // RAW mode previews are enlarged in Flutter. Convert the visible tap back
    // into the underlying native preview coordinates before AVFoundation maps
    // it to the camera sensor's focus/exposure coordinate system.
    final visibleFraction = 1.0 / widget.softwareZoom;
    final offsetFraction = (1.0 - visibleFraction) / 2.0;
    final previewX = offsetFraction + (visibleX * visibleFraction);
    final previewY = offsetFraction + (visibleY * visibleFraction);

    widget.onTap!(previewX.clamp(0.0, 1.0), previewY.clamp(0.0, 1.0));
  }

  @override
  void dispose() {
    _reticleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = _aspectValue(widget.aspectRatio);

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableW = constraints.maxWidth;
        final availableH = constraints.maxHeight;

        double previewW = availableW;
        double previewH = previewW / target;

        if (previewH > availableH) {
          previewH = availableH;
          previewW = previewH * target;
        }

        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: SizedBox(
              width: previewW,
              height: previewH,
              child: ClipRect(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  // Listener receives the pointer immediately, unlike a
                  // GestureDetector competing with the native UiKitView.
                  onPointerDown: (event) =>
                      _handleTapAt(event.localPosition, previewW, previewH),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Transform.scale(
                        scale: widget.softwareZoom,
                        alignment: Alignment.center,
                        child: const UiKitView(
                          viewType: 'native_camera_preview',
                          creationParams: null,
                          creationParamsCodec: StandardMessageCodec(),
                        ),
                      ),
                      if (_reticlePoint != null)
                        Positioned(
                          left: _reticlePoint!.dx - 35,
                          top: _reticlePoint!.dy - 35,
                          child: IgnorePointer(
                            child: TweenAnimationBuilder<double>(
                              key: ValueKey(_reticlePoint),
                              tween: Tween<double>(begin: 1.35, end: 1.0),
                              duration: const Duration(milliseconds: 250),
                              builder: (context, scale, child) =>
                                  Transform.scale(scale: scale, child: child),
                              child: Container(
                                width: 70,
                                height: 70,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.amber,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
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

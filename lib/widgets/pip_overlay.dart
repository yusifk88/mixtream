import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/pip_camera_service.dart';
import '../services/video_mixer_service.dart';

class PipOverlay extends StatefulWidget {
  final PipCameraService cameraService;
  final VideoMixerService? mixer;
  final double cornerRadius;
  final int shadowAlpha;
  final double zoom;

  const PipOverlay({
    super.key,
    required this.cameraService,
    this.mixer,
    this.cornerRadius = 14,
    this.shadowAlpha = 70,
    this.zoom = 1.0,
  });

  @override
  State<PipOverlay> createState() => _PipOverlayState();
}

class _PipOverlayState extends State<PipOverlay> {
  ui.Image? _frame;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    if (widget.mixer != null) {
      _subscription = widget.mixer!.pipPreviewFrames.listen(_onMixerFrame);
    } else {
      _subscription = widget.cameraService.frames.listen(_onCameraFrame);
    }
  }

  void _onCameraFrame(PipFrame frame) {
    if (!mounted) return;
    ui.decodeImageFromPixels(
      frame.pixels, frame.width, frame.height, ui.PixelFormat.rgba8888,
      (image) {
        if (mounted) setState(() => _frame = image);
      },
    );
  }

  void _onMixerFrame(CompositedFrame frame) {
    if (!mounted) return;
    ui.decodeImageFromPixels(
      frame.pixels, frame.width, frame.height, ui.PixelFormat.rgba8888,
      (image) {
        if (mounted) setState(() => _frame = image);
      },
    );
  }

  @override
  void didUpdateWidget(PipOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mixer != widget.mixer) {
      _subscription?.cancel();
      _subscribe();
    }
    if (oldWidget.zoom != widget.zoom ||
        oldWidget.cornerRadius != widget.cornerRadius ||
        oldWidget.shadowAlpha != widget.shadowAlpha) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_frame == null) {
      if (defaultTargetPlatform == TargetPlatform.iOS && widget.mixer == null) {
        return Container(
          color: Colors.black,
          child: const Center(child: Text('PiP active during\nrecording', style: TextStyle(color: Colors.white38, fontSize: 11))),
        );
      }
      return Container(color: Colors.black);
    }
    final cr = widget.cornerRadius.clamp(0.0, 30.0);
    final sa = widget.shadowAlpha.clamp(0, 255);
    final zm = widget.zoom.clamp(1.0, 3.0);
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: sa / 255),
            blurRadius: 12,
            offset: const Offset(3, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(cr),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            return ClipRect(
              child: Transform.scale(
                scale: zm,
                alignment: Alignment.center,
                child: RawImage(
                  image: _frame,
                  fit: BoxFit.cover,
                  width: w,
                  height: h,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

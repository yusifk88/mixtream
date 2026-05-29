import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../services/video_mixer_service.dart';

class MixerPreview extends StatefulWidget {
  final VideoMixerService mixer;
  const MixerPreview({super.key, required this.mixer});

  @override
  State<MixerPreview> createState() => _MixerPreviewState();
}

class _MixerPreviewState extends State<MixerPreview> {
  ui.Image? _frame;
  StreamSubscription<CompositedFrame>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.mixer.previewFrames.listen(_onFrame);
  }

  void _onFrame(CompositedFrame frame) {
    if (!mounted) return;
    ui.decodeImageFromPixels(
      frame.pixels, frame.width, frame.height, ui.PixelFormat.rgba8888,
      (image) {
        if (mounted) setState(() => _frame = image);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = widget.mixer.mainTextureId;
    if (textureId != null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final double deviceRatio = size.width / size.height;
          final double textureRatio = 360 / 640;
          double scale = textureRatio / deviceRatio;
          if (scale < 1.0) scale = 1.0 / scale;
          return ClipRect(
            child: Transform.scale(
              scale: scale,
              child: Center(
                child: SizedBox(
                  width: 360,
                  height: 640,
                  child: Texture(textureId: textureId),
                ),
              ),
            ),
          );
        },
      );
    }
    if (_frame == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.cyan));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final double deviceRatio = size.width / size.height;
        final double frameRatio = (_frame!.width / _frame!.height);
        double scale = frameRatio / deviceRatio;
        if (scale < 1.0) scale = 1.0 / scale;
        return ClipRect(
          child: Transform.scale(
            scale: scale,
            child: Center(
              child: RawImage(
                image: _frame,
                fit: BoxFit.contain,
              ),
            ),
          ),
        );
      },
    );
  }
}

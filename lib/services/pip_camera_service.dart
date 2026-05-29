import 'dart:async';
import 'package:flutter/services.dart';

class PipFrame {
  final int width;
  final int height;
  final Uint8List pixels;
  PipFrame(this.width, this.height, this.pixels);
}

class PipCameraService {
  static const _methodChannel = MethodChannel('com.example.learningflutter/pip_camera');
  static const _eventChannel = EventChannel('com.example.learningflutter/pip_frames');

  StreamSubscription<dynamic>? _subscription;
  final _frameController = StreamController<PipFrame>.broadcast();

  Stream<PipFrame> get frames => _frameController.stream;

  Future<bool> start({int width = 320, int height = 240, required bool frontCamera}) async {
    bool hasNative = true;
    try {
      await _methodChannel.invokeMethod('start', {
        'width': width,
        'height': height,
        'frontCamera': frontCamera,
      });
    } on MissingPluginException {
      hasNative = false;
    }
    if (hasNative) {
      _subscription = _eventChannel.receiveBroadcastStream().listen(
        (data) {
          if (data is Map) {
            final w = data['width'] as int;
            final h = data['height'] as int;
            final p = data['pixels'] as Uint8List;
            _frameController.add(PipFrame(w, h, p));
          }
        },
      );
    }
    return true;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methodChannel.invokeMethod('stop');
    } on MissingPluginException {
      // iOS doesn't implement pip_camera channel
    }
  }

  void dispose() {
    _subscription?.cancel();
    _frameController.close();
  }
}

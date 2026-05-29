import 'dart:async';
import 'package:flutter/services.dart';

enum RecordingState { idle, starting, recording, stopped, error }

class CompositedFrame {
  final int width;
  final int height;
  final Uint8List pixels;
  CompositedFrame(this.width, this.height, this.pixels);
}

class VideoMixerService {
  static const _methodChannel = MethodChannel('com.example.learningflutter/video_mixer');
  static const _previewChannel = EventChannel('com.example.learningflutter/mixer_preview');
  static const _pipPreviewChannel = EventChannel('com.example.learningflutter/mixer_pip_preview');

  final StreamController<RecordingState> _stateController = StreamController<RecordingState>.broadcast();
  Stream<RecordingState> get stateStream => _stateController.stream;

  final StreamController<CompositedFrame> _previewController = StreamController<CompositedFrame>.broadcast();
  Stream<CompositedFrame> get previewFrames => _previewController.stream;

  final StreamController<CompositedFrame> _pipPreviewController = StreamController<CompositedFrame>.broadcast();
  Stream<CompositedFrame> get pipPreviewFrames => _pipPreviewController.stream;

  RecordingState _state = RecordingState.idle;
  RecordingState get state => _state;

  int? _mainTextureId;
  int? get mainTextureId => _mainTextureId;

  StreamSubscription<dynamic>? _previewSub;
  StreamSubscription<dynamic>? _pipPreviewSub;

  Future<void> startRecording({
    bool useMainFront = false,
    bool useFrontPiP = true,
    bool pipEnabled = true,
    int outputWidth = 1080,
    int outputHeight = 1920,
    double pipNormX = 0.82,
    double pipNormY = 0.11,
    double pipNormW = 0.17,
    double pipNormH = 0.22,
    double pipCornerRadius = 14,
    int pipShadowAlpha = 70,
    double pipZoom = 1.0,
    List<Map<String, dynamic>>? photos,
  }) async {
    if (_state == RecordingState.recording) return;
    _state = RecordingState.starting;
    _stateController.add(_state);

    try {
      final args = <String, dynamic>{
        'useMainFront': useMainFront,
        'useFrontPiP': useFrontPiP,
        'pipEnabled': pipEnabled,
        'outputWidth': outputWidth,
        'outputHeight': outputHeight,
        'pipNormX': pipNormX,
        'pipNormY': pipNormY,
        'pipNormW': pipNormW,
        'pipNormH': pipNormH,
        'pipCornerRadius': pipCornerRadius,
        'pipShadowAlpha': pipShadowAlpha,
        'pipZoom': pipZoom,
      };
      if (photos != null && photos.isNotEmpty) {
        args['photos'] = photos;
      }
      final result = await _methodChannel.invokeMethod<Map>('startRecording', args);
      _mainTextureId = result?['textureId'] as int?;
      _stateController.add(_state);

      _previewSub = _previewChannel.receiveBroadcastStream().listen((data) {
        if (data is Map) {
          _previewController.add(CompositedFrame(
            data['width'] as int,
            data['height'] as int,
            data['pixels'] as Uint8List,
          ));
        }
      });

      _pipPreviewSub = _pipPreviewChannel.receiveBroadcastStream().listen((data) {
        if (data is Map) {
          _pipPreviewController.add(CompositedFrame(
            data['width'] as int,
            data['height'] as int,
            data['pixels'] as Uint8List,
          ));
        }
      });

      _state = RecordingState.recording;
      _stateController.add(_state);
    } catch (e) {
      _state = RecordingState.error;
      _stateController.add(_state);
      rethrow;
    }
  }

  Future<void> addPhoto({
    required String id,
    required Uint8List data,
    required double normX,
    required double normY,
    required double normW,
    required double normH,
  }) async {
    try {
      await _methodChannel.invokeMethod('addPhoto', {
        'id': id,
        'data': data,
        'normX': normX,
        'normY': normY,
        'normW': normW,
        'normH': normH,
      });
    } catch (_) {}
  }

  Future<void> updatePipZoom(double zoom) async {
    try {
      await _methodChannel.invokeMethod('updatePipZoom', {'zoom': zoom});
    } catch (_) {}
  }

  Future<void> updatePipConfig({
    required double pipNormX,
    required double pipNormY,
    required double pipNormW,
    required double pipNormH,
    required double pipCornerRadius,
    required int pipShadowAlpha,
    required double pipZoom,
    required bool pipEnabled,
    List<Map<String, dynamic>>? photos,
  }) async {
    try {
      final args = <String, dynamic>{
        'pipNormX': pipNormX,
        'pipNormY': pipNormY,
        'pipNormW': pipNormW,
        'pipNormH': pipNormH,
        'pipCornerRadius': pipCornerRadius,
        'pipShadowAlpha': pipShadowAlpha,
        'pipZoom': pipZoom,
        'pipEnabled': pipEnabled,
      };
      if (photos != null && photos.isNotEmpty) {
        args['photos'] = photos;
      }
      await _methodChannel.invokeMethod('updatePipConfig', args);
    } catch (_) {}
  }

  Future<String?> stopRecording() async {
    if (_state != RecordingState.recording) return null;
    _state = RecordingState.stopped;
    _stateController.add(_state);

    _mainTextureId = null;

    await _previewSub?.cancel();
    _previewSub = null;
    await _pipPreviewSub?.cancel();
    _pipPreviewSub = null;

    String? path;
    try {
      path = await _methodChannel.invokeMethod<String>('stopRecording');
    } catch (e) {
      // Native error — proceed to idle state
    }
    _state = RecordingState.idle;
    _stateController.add(RecordingState.idle);
    return path;
  }

  void dispose() {
    _previewSub?.cancel();
    _pipPreviewSub?.cancel();
    _previewController.close();
    _pipPreviewController.close();
    _stateController.close();
  }
}

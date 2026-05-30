import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'widgets/camera_feed.dart';
import 'widgets/camera_overlay.dart';
import 'widgets/control_dock.dart';
import 'widgets/pip_overlay.dart';
import 'services/pip_camera_service.dart';
import 'services/video_mixer_service.dart';
import 'services/notification_service.dart';
import 'widgets/mixer_preview.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MixStream Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F111A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.cyan,
          brightness: Brightness.dark,
          primary: Colors.cyan,
          secondary: Colors.blueAccent,
        ),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'MixStream Pro Studio'),
    );
  }
}

class _PhotoOverlay {
  final String id;
  final File file;
  final Uint8List cachedBytes;
  Offset position;
  Size size;
  bool initialized;

  _PhotoOverlay({
    required this.id,
    required this.file,
    required this.cachedBytes,
    this.position = Offset.zero,
    this.size = const Size(180, 240),
    this.initialized = false,
  });
}
class _VideoOverlay {
  final String id;
  final File file;
  VideoPlayerController controller;
  Offset position;
  Size size;
  bool initialized;
  bool isPlaying;

  _VideoOverlay({
    required this.id,
    required this.file,
    required this.controller,
    this.position = Offset.zero,
    this.size = const Size(180, 240),
    this.initialized = false,
    this.isPlaying = false,
  });
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final int _counter = 0;

  // Camera State
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isCameraInitializing = true;
  String _cameraError = '';
  int _selectedCameraIndex = 0;

  // PiP State
  bool _isPiPMode = false;
  final PipCameraService _pipCameraService = PipCameraService();
  Offset _pipPosition = Offset.zero;
  bool _pipInitialized = false;
  Size _pipSize = const Size(120, 160);

  // PiP control settings
  double _pipCornerRadius = 14;
  int _pipShadowAlpha = 70;
  double _pipZoom = 1.0;

  // Photo overlay state (multi-photo support)
  final List<_PhotoOverlay> _photoOverlays = [];
  int _nextPhotoId = 0;

  // Video overlay state
  final List<_VideoOverlay> _videoOverlays = [];
  int _nextVideoId = 0;

  // Edge light
  bool _isEdgeLightOn = false;

  // Notifications
  final NotificationService _notifications = NotificationService();

  // Recording (native dual-camera mixer)
  final VideoMixerService _mixer = VideoMixerService();
  bool _isRecording = false;
  StreamSubscription<RecordingState>? _recSub;

  @override
  void initState() {
    super.initState();
    _notifications.init();
    _initCamera();
    _recSub = _mixer.stateStream.listen(_onRecStateChanged);
  }

  void _onRecStateChanged(RecordingState state) async {
    if (!mounted) return;
    switch (state) {
      case RecordingState.starting:
        _isRecording = true;
        await _pipCameraService.stop();
        setState(() {});
        break;
      case RecordingState.recording:
        _isRecording = true;
        await _notifications.showRecordingProgress();
        setState(() {});
        break;
      case RecordingState.stopped:
        setState(() {});
        break;
      case RecordingState.idle:
        if (_isRecording) {
          _isRecording = false;
          setState(() {});
          // Restart pip camera if PiP mode was enabled before recording
          if (_isPiPMode) {
            final mainLens = _cameras[_selectedCameraIndex].lensDirection;
            final useFront = mainLens != CameraLensDirection.front;
            try {
              await _pipCameraService.start(frontCamera: useFront);
            } catch (_) {}
          }
          _initCamera();
        }
        break;
      case RecordingState.error:
        _isRecording = false;
        await _notifications.showRecordingError();
        setState(() {});
        _initCamera();
        break;
    }
  }

  Future<void> _initCamera() async {
    setState(() {
      _isCameraInitializing = true;
      _cameraError = '';
    });

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _cameraError = 'No cameras found';
          _isCameraInitializing = false;
        });
        return;
      }
      await _setupCameraController(_cameras[_selectedCameraIndex]);
    } catch (e) {
      setState(() {
        _cameraError = 'Failed to load cameras: $e';
        _isCameraInitializing = false;
      });
    }
  }

  Future<void> _setupCameraController(CameraDescription cameraDescription) async {
    if (_cameraController != null) {
      await _cameraController!.dispose();
    }

    _cameraController = CameraController(
      cameraDescription,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _isCameraInitializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cameraError = 'Failed to initialize camera: $e';
          _isCameraInitializing = false;
        });
      }
    }
  }

  void _toggleCamera() async {
    if (_cameras.length < 2) return;
    if (_isPiPMode) {
      await _pipCameraService.stop();
      setState(() {
        _isPiPMode = false;
        _pipInitialized = false;
      });
    }
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    setState(() {
      _isCameraInitialized = false;
      _isCameraInitializing = true;
    });
    await _setupCameraController(_cameras[_selectedCameraIndex]);
  }

  void _togglePiPMode() async {
    if (_isPiPMode) {
      if (!_isRecording) {
        await _pipCameraService.stop();
      }
      if (mounted) {
        setState(() {
          _isPiPMode = false;
          _pipInitialized = false;
        });
      }
    } else {
      if (_isRecording) {
        if (mounted) {
          setState(() => _isPiPMode = true);
        }
      } else {
        final mainLens = _cameras[_selectedCameraIndex].lensDirection;
        final useFront = mainLens != CameraLensDirection.front;
        try {
          await _pipCameraService.start(frontCamera: useFront);
          if (mounted) {
            setState(() => _isPiPMode = true);
          }
        } catch (_) {}
      }
    }
    _syncPipConfig();
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _mixer.stopRecording();
      if (mounted) {
        await _notifications.showRecordingSaved(path: path);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(path != null ? 'Recording saved' : 'Recording stopped'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } else {
      if (_cameras.isEmpty) return;

      // Request microphone permission right before recording
      final micStatus = await Permission.microphone.request();
      if (micStatus.isPermanentlyDenied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission permanently denied. Enable it in Settings.')),
          );
        }
        return;
      }
      if (micStatus.isDenied && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied — recording without audio')),
        );
      }

      final mainLens = _cameras[_selectedCameraIndex].lensDirection;
      final useMainFront = mainLens == CameraLensDirection.front;
      final useFrontPiP = !useMainFront;
      final screenW = MediaQuery.of(context).size.width;
      final screenH = MediaQuery.of(context).size.height;
      // Build photo list from cached bytes
      final List<Map<String, dynamic>> photoList = _photoOverlays.map((p) => {
        'id': p.id,
        'data': p.cachedBytes,
        'normX': p.position.dx / screenW,
        'normY': p.position.dy / screenH,
        'normW': p.size.width / screenW,
        'normH': p.size.height / screenH,
      }).toList();
      // Build video list from file paths
      final List<Map<String, dynamic>> videoList = _videoOverlays.map((v) => {
        'id': v.id,
        'path': v.file.path,
        'normX': v.position.dx / screenW,
        'normY': v.position.dy / screenH,
        'normW': v.size.width / screenW,
        'normH': v.size.height / screenH,
        'isPlaying': v.isPlaying,
      }).toList();
      // Release Flutter camera before native recording starts
      await _cameraController?.dispose();
      _cameraController = null;
      _isCameraInitialized = false;
      _isCameraInitializing = false;
      await _mixer.startRecording(
        useMainFront: useMainFront,
        useFrontPiP: useFrontPiP,
        pipEnabled: _isPiPMode,
        pipNormX: _pipPosition.dx / screenW,
        pipNormY: _pipPosition.dy / screenH,
        pipNormW: _pipSize.width / screenW,
        pipNormH: _pipSize.height / screenH,
        pipCornerRadius: _pipCornerRadius,
        pipShadowAlpha: _pipShadowAlpha,
        pipZoom: _pipZoom,
        photos: photoList,
        videos: videoList,
      );
    }
  }

  void _syncPipConfig() {
    if (!_isRecording) return;
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final photoList = _photoOverlays.map((p) => {
      'id': p.id,
      'normX': p.position.dx / screenW,
      'normY': p.position.dy / screenH,
      'normW': p.size.width / screenW,
      'normH': p.size.height / screenH,
    }).toList();
    final videoList = _videoOverlays.map((v) => {
      'id': v.id,
      'normX': v.position.dx / screenW,
      'normY': v.position.dy / screenH,
      'normW': v.size.width / screenW,
      'normH': v.size.height / screenH,
      'isPlaying': v.isPlaying,
    }).toList();
    _mixer.updatePipConfig(
      pipNormX: _pipPosition.dx / screenW,
      pipNormY: _pipPosition.dy / screenH,
      pipNormW: _pipSize.width / screenW,
      pipNormH: _pipSize.height / screenH,
      pipCornerRadius: _pipCornerRadius,
      pipShadowAlpha: _pipShadowAlpha,
      pipZoom: _pipZoom,
      pipEnabled: _isPiPMode,
      photos: photoList,
      videos: videoList,
    );
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked != null) {
      final id = 'photo_${_nextPhotoId++}';
      final bytes = await File(picked.path).readAsBytes();
      setState(() {
        _photoOverlays.add(_PhotoOverlay(
          id: id,
          file: File(picked.path),
          cachedBytes: bytes,
        ));
      });
      if (_isRecording) {
        final screenW = MediaQuery.of(context).size.width;
        final screenH = MediaQuery.of(context).size.height;
        await _mixer.addPhoto(
          id: id,
          data: bytes,
          normX: 0,
          normY: 0,
          normW: 180 / screenW,
          normH: 240 / screenH,
        );
        _syncPipConfig();
      }
    }
  }

  void _removePhoto(String id) {
    setState(() {
      _photoOverlays.removeWhere((p) => p.id == id);
    });
    _syncPipConfig();
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    if (picked != null) {
      final id = 'video_${_nextVideoId++}';
      final file = File(picked.path);
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      setState(() {
        _videoOverlays.add(_VideoOverlay(
          id: id,
          file: file,
          controller: controller,
        ));
      });
      if (_isRecording) {
        final screenW = MediaQuery.of(context).size.width;
        final screenH = MediaQuery.of(context).size.height;
        await _mixer.addVideo(
          id: id,
          path: picked.path,
          normX: 0,
          normY: 0,
          normW: 180 / screenW,
          normH: 240 / screenH,
        );
        _syncPipConfig();
      }
    }
  }

  void _toggleVideoPlayback(String id) {
    final overlay = _videoOverlays.firstWhere((v) => v.id == id);
    if (overlay.isPlaying) {
      overlay.controller.pause();
    } else {
      overlay.controller.play();
    }
    setState(() {
      overlay.isPlaying = !overlay.isPlaying;
    });
    _syncPipConfig();
  }

  void _removeVideo(String id) {
    final overlay = _videoOverlays.firstWhere((v) => v.id == id);
    overlay.controller.dispose();
    setState(() {
      _videoOverlays.removeWhere((v) => v.id == id);
    });
    _syncPipConfig();
  }

  // Photo overlay (multi-photo)
  Widget _buildPhotoOverlay(double maxW, double maxH) {
    const minSize = Size(100, 130);
    return Stack(
      children: _photoOverlays.map((photo) {
        if (!photo.initialized) {
          photo.initialized = true;
          final baseX = 16.0 + (_photoOverlays.indexOf(photo) * 30) % (maxW - photo.size.width - 16);
          final baseY = 100.0 + (_photoOverlays.indexOf(photo) * 40) % (maxH - photo.size.height - 100);
          photo.position = Offset(baseX, baseY);
        }
        final clampedTop = photo.position.dy.clamp(0.0, maxH - photo.size.height);
        final clampedLeft = photo.position.dx.clamp(0.0, maxW - photo.size.width);
        return Positioned(
          key: ValueKey(photo.id),
          top: clampedTop,
          left: clampedLeft,
          width: photo.size.width,
          height: photo.size.height,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 2),
              borderRadius: BorderRadius.circular(_pipCornerRadius.clamp(0, 30) + 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: _pipShadowAlpha.clamp(0, 255) / 255),
                  blurRadius: 12,
                  offset: const Offset(3, 7),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_pipCornerRadius.clamp(0, 30)),
              child: Stack(
                children: [
                  ClipRect(
                    child: Transform.scale(
                      scale: _pipZoom.clamp(1.0, 3.0),
                      alignment: Alignment.center,
                      child: Image.file(photo.file, fit: BoxFit.cover, width: photo.size.width, height: photo.size.height),
                    ),
                  ),
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanUpdate: (details) {
                        setState(() {
                          photo.position = Offset(
                            (clampedLeft + details.delta.dx).clamp(0.0, maxW - photo.size.width),
                            (clampedTop + details.delta.dy).clamp(0.0, maxH - photo.size.height),
                          );
                        });
                        _syncPipConfig();
                      },
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                  // Close button
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => _removePhoto(photo.id),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Icon(Icons.close, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                  // Resize handle
                  Positioned(
                    right: 0,
                    bottom: 0,
                    width: 28,
                    height: 28,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        setState(() {
                          photo.size = Size(
                            (photo.size.width + details.delta.dx).clamp(minSize.width, maxW - clampedLeft),
                            (photo.size.height + details.delta.dy).clamp(minSize.height, maxH - clampedTop),
                          );
                        });
                        _syncPipConfig();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.drag_indicator, size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // Video overlay (multi-video support)
  Widget _buildVideoOverlay(double maxW, double maxH) {
    const minSize = Size(100, 130);
    return Stack(
      children: _videoOverlays.map((video) {
        if (!video.initialized) {
          video.initialized = true;
          final baseX = 16.0 + (_videoOverlays.indexOf(video) * 30) % (maxW - video.size.width - 16);
          final baseY = 380.0 + (_videoOverlays.indexOf(video) * 40) % (maxH - video.size.height - 380);
          video.position = Offset(baseX, baseY);
        }
        final clampedTop = video.position.dy.clamp(0.0, maxH - video.size.height);
        final clampedLeft = video.position.dx.clamp(0.0, maxW - video.size.width);
        return Positioned(
          key: ValueKey(video.id),
          top: clampedTop,
          left: clampedLeft,
          width: video.size.width,
          height: video.size.height,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 2),
              borderRadius: BorderRadius.circular(_pipCornerRadius.clamp(0, 30) + 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: _pipShadowAlpha.clamp(0, 255) / 255),
                  blurRadius: 12,
                  offset: const Offset(3, 7),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_pipCornerRadius.clamp(0, 30)),
              child: Stack(
                children: [
                  ClipRect(
                    child: Transform.scale(
                      scale: _pipZoom.clamp(1.0, 3.0),
                      alignment: Alignment.center,
                      child: VideoPlayer(video.controller),
                    ),
                  ),
                  // Play/pause + drag overlay
                  Positioned.fill(
                    child: GestureDetector(
                      onTapUp: (details) {
                        final localPos = details.localPosition;
                        final size = video.size;
                        // Ignore tap in resize handle area (bottom-right 28x28)
                        if (localPos.dx >= size.width - 28 && localPos.dy >= size.height - 28) return;
                        // Ignore tap on close button area (top-right 26x26)
                        if (localPos.dx >= size.width - 26 && localPos.dy <= 26) return;
                        _toggleVideoPlayback(video.id);
                      },
                      onPanUpdate: (details) {
                        setState(() {
                          video.position = Offset(
                            (clampedLeft + details.delta.dx).clamp(0.0, maxW - video.size.width),
                            (clampedTop + details.delta.dy).clamp(0.0, maxH - video.size.height),
                          );
                        });
                        _syncPipConfig();
                      },
                      child: Container(
                        color: Colors.transparent,
                        child: Stack(
                          children: [
                            if (!video.isPlaying)
                              Center(
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 28),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Close button
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: () => _removeVideo(video.id),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Icon(Icons.close, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                  // Resize handle
                  Positioned(
                    right: 0,
                    bottom: 0,
                    width: 28,
                    height: 28,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        setState(() {
                          video.size = Size(
                            (video.size.width + details.delta.dx).clamp(minSize.width, maxW - clampedLeft),
                            (video.size.height + details.delta.dy).clamp(minSize.height, maxH - clampedTop),
                          );
                        });
                        _syncPipConfig();
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.drag_indicator, size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _pipCameraService.dispose();
    _recSub?.cancel();
    _mixer.dispose();
    _notifications.cancelAll();
    for (final v in _videoOverlays) {
      v.controller.dispose();
    }
    super.dispose();
  }

  void _showAlertDialog() {
    final BuildContext ctx = context;
    showDialog<void>(
      context: ctx,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Alert"),
        content: const Text("Button was pressed!"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width;
    final maxH = MediaQuery.of(context).size.height;
    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 44,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add_rounded, color: Colors.cyanAccent),
            tooltip: 'New content',
            onSelected: (value) {
              if (value == 'photo') _pickPhoto();
              if (value == 'video') _pickVideo();
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'photo', child: Row(children: [const Icon(Icons.photo_camera_outlined, size: 20), const SizedBox(width: 12), const Text('Photo')])),
              PopupMenuItem(value: 'video', child: Row(children: [const Icon(Icons.videocam_outlined, size: 20), const SizedBox(width: 12), const Text('Video')])),
              PopupMenuItem(value: 'gif', child: Row(children: [const Icon(Icons.gif_box_outlined, size: 20), const SizedBox(width: 12), const Text('GIF')])),
              PopupMenuItem(value: 'text', child: Row(children: [const Icon(Icons.text_fields, size: 20), const SizedBox(width: 12), const Text('Text')])),
            ],
          ),
          if (_cameras.length > 1 && !_isRecording)
            IconButton(
              icon: const Icon(Icons.flip_camera_ios, color: Colors.cyanAccent),
              onPressed: _toggleCamera,
              tooltip: 'Switch Camera',
            ),
          if (_cameras.length > 1)
            IconButton(
              icon: Icon(
                _isPiPMode ? Icons.picture_in_picture_alt : Icons.picture_in_picture_alt_outlined,
                color: _isPiPMode ? Colors.cyanAccent : Colors.white70,
              ),
              onPressed: _togglePiPMode,
              tooltip: _isPiPMode ? 'Disable PiP' : 'Enable PiP',
            ),
        ],
      ),
      body: Stack(
        children: [
          // Camera feed — live preview or mixer preview during recording
          Positioned.fill(
            child: _isRecording
                ? MixerPreview(mixer: _mixer)
                : CameraFeed(
                    isCameraInitializing: _isCameraInitializing,
                    isCameraInitialized: _isCameraInitialized,
                    cameraController: _cameraController,
                    cameraError: _cameraError,
                  ),
          ),

          // Top gradient shadow
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 140,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.5),
                      Colors.transparent,
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ),
          ),

          // Edge ring light
          if (_isEdgeLightOn)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 0.95,
                      colors: [
                        Colors.transparent,
                        Colors.transparent,
                        const Color(0xFFFFF0D0).withValues(alpha: 0.3),
                        const Color(0xFFFFF0D0).withValues(alpha: 0.8),
                        const Color(0xFFFFF0D0),
                      ],
                      stops: const [0.0, 0.85, 0.93, 0.98, 1.0],
                    ),
                  ),
                ),
              ),
            ),

          // HUD overlays
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 56.0, bottom: 140.0),
              child: CameraOverlay(
                isCameraInitialized: _isCameraInitialized || _isRecording,
              ),
            ),
          ),

          // PiP overlay — shown when enabled
          if (_isPiPMode) _buildPipOverlay(maxW, maxH),

          // Photo overlay (multi-photo)
          if (_photoOverlays.isNotEmpty) _buildPhotoOverlay(maxW, maxH),

          // Video overlay (multi-video)
          if (_videoOverlays.isNotEmpty) _buildVideoOverlay(maxW, maxH),

          // Recording indicator overlay
          if (_isRecording)
            Positioned(
              top: MediaQuery.of(context).padding.top + 60,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fiber_manual_record_rounded, color: Colors.white, size: 14),
                    SizedBox(width: 4),
                    Text('REC', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),

          // Bottom control dock
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ControlDock(
              counter: _counter,
              isRecording: _isRecording,
              isPiPMode: _isPiPMode,
              isEdgeLightOn: _isEdgeLightOn,
              onRecordPressed: _toggleRecording,
              onShowAlertPressed: _showAlertDialog,
              pipCornerRadius: _pipCornerRadius,
              pipShadowAlpha: _pipShadowAlpha,
              pipZoom: _pipZoom,
              onPipCornerRadiusChanged: (v) {
                setState(() => _pipCornerRadius = v);
                _syncPipConfig();
              },
              onPipShadowAlphaChanged: (v) {
                setState(() => _pipShadowAlpha = v);
                _syncPipConfig();
              },
              onPipZoomChanged: (v) {
                setState(() => _pipZoom = v);
                _syncPipConfig();
              },
              onEdgeLightChanged: (v) {
                setState(() => _isEdgeLightOn = v);
              },
            ),
          ),
        ],
      ),
    );
  }

  // PiP overlay
  Widget _buildPipOverlay(double maxW, double maxH) {
    const minSize = Size(80, 100);
    if (!_pipInitialized) {
      _pipInitialized = true;
      _pipPosition = Offset(maxW - _pipSize.width - 16, 100);
    }
    final clampedTop = _pipPosition.dy.clamp(0.0, maxH - _pipSize.height);
    final clampedLeft = _pipPosition.dx.clamp(0.0, maxW - _pipSize.width);
    final cr = _pipCornerRadius.clamp(0, 30).toDouble();
    return Positioned(
      top: clampedTop,
      left: clampedLeft,
      width: _pipSize.width,
      height: _pipSize.height,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.6), width: 2),
          borderRadius: BorderRadius.circular(cr + 2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(cr),
          child: Stack(
            children: [
              PipOverlay(
                cameraService: _pipCameraService,
                mixer: _isRecording ? _mixer : null,
                cornerRadius: _pipCornerRadius.clamp(0, 30).toDouble(),
                shadowAlpha: _pipShadowAlpha.clamp(0, 255),
                zoom: _pipZoom.clamp(1.0, 3.0),
              ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanUpdate: (details) {
                    setState(() {
                      _pipPosition = Offset(
                        (clampedLeft + details.delta.dx).clamp(0.0, maxW - _pipSize.width),
                        (clampedTop + details.delta.dy).clamp(0.0, maxH - _pipSize.height),
                      );
                    });
                    _syncPipConfig();
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                width: 28,
                height: 28,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) {
                    setState(() {
                      _pipSize = Size(
                        (_pipSize.width + details.delta.dx).clamp(minSize.width, maxW - clampedLeft),
                        (_pipSize.height + details.delta.dy).clamp(minSize.height, maxH - clampedTop),
                      );
                    });
                    _syncPipConfig();
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.cyanAccent.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Icons.drag_indicator, size: 18, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

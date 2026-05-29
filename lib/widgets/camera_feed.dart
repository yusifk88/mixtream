import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

class CameraFeed extends StatelessWidget {
  final bool isCameraInitializing;
  final bool isCameraInitialized;
  final CameraController? cameraController;
  final String cameraError;

  const CameraFeed({
    super.key,
    required this.isCameraInitializing,
    required this.isCameraInitialized,
    required this.cameraController,
    required this.cameraError,
  });

  @override
  Widget build(BuildContext context) {
    if (isCameraInitializing) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.cyan),
            SizedBox(height: 16),
            Text(
              'Initializing optical sensors...',
              style: TextStyle(color: Colors.cyan, letterSpacing: 1.1),
            ),
          ],
        ),
      );
    }

    if (isCameraInitialized && cameraController != null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final double deviceRatio = size.width / size.height;
          double cameraRatio = cameraController!.value.aspectRatio;

          // Normalize cameraRatio to match screen orientation if necessary
          if (size.height > size.width && cameraRatio > 1.0) {
            cameraRatio = 1 / cameraRatio;
          } else if (size.width > size.height && cameraRatio < 1.0) {
            cameraRatio = 1 / cameraRatio;
          }

          // Calculate scale factor to cover the entire container
          double scale = cameraRatio / deviceRatio;
          if (scale < 1.0) scale = 1.0 / scale;

          return ClipRect(
            child: Transform.scale(
              scale: scale,
              child: Center(
                child: CameraPreview(cameraController!),
              ),
            ),
          );
        },
      );
    }

    // Fallback UI (e.g. running on simulator)
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E2235), Color(0xFF0F111A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Cyberpunk futuristic HUD grid/radar effect
          Opacity(
            opacity: 0.15,
            child: GridPaper(
              color: Colors.cyanAccent,
              divisions: 2,
              subdivisions: 4,
            ),
          ),
          
          // Lens mock / shutter graphic
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.cyan.withOpacity(0.2),
                width: 2.0,
              ),
              gradient: RadialGradient(
                colors: [
                  Colors.cyan.withOpacity(0.05),
                  Colors.transparent,
                ],
              ),
            ),
            child: Center(
              child: Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.cyan.withOpacity(0.4),
                    width: 1.0,
                  ),
                ),
                child: const Icon(
                  Icons.videocam_rounded,
                  size: 64,
                  color: Colors.cyan,
                ),
              ),
            ),
          ),
          
          // Fallback message
          Positioned(
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3), width: 1),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'SIMULATION FEED',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cameraError.isNotEmpty ? cameraError : 'Camera hardware not detected.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

class CameraOverlay extends StatelessWidget {
  final bool isCameraInitialized;

  const CameraOverlay({
    super.key,
    required this.isCameraInitialized,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // Center viewfinder brackets
        Center(
          child: Icon(
            Icons.center_focus_weak,
            size: 48,
            color: Colors.white.withOpacity(0.3),
          ),
        ),

        // Bottom status bar
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ISO 400',
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10, fontFamily: 'monospace'),
              ),
              Text(
                'EV 0.0',
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10, fontFamily: 'monospace'),
              ),
              Text(
                'AUTO',
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 10, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'dart:ui';

class ControlDock extends StatefulWidget {
  final int counter;
  final bool isRecording;
  final bool isPiPMode;
  final bool isEdgeLightOn;
  final VoidCallback onRecordPressed;
  final VoidCallback onShowAlertPressed;
  final double pipCornerRadius;
  final int pipShadowAlpha;
  final double pipZoom;
  final ValueChanged<double> onPipCornerRadiusChanged;
  final ValueChanged<int> onPipShadowAlphaChanged;
  final ValueChanged<double> onPipZoomChanged;
  final ValueChanged<bool> onEdgeLightChanged;

  const ControlDock({
    super.key,
    required this.counter,
    this.isRecording = false,
    this.isPiPMode = false,
    this.isEdgeLightOn = false,
    required this.onRecordPressed,
    required this.onShowAlertPressed,
    this.pipCornerRadius = 14,
    this.pipShadowAlpha = 70,
    this.pipZoom = 1.0,
    required this.onPipCornerRadiusChanged,
    required this.onPipShadowAlphaChanged,
    required this.onPipZoomChanged,
    required this.onEdgeLightChanged,
  });

  @override
  State<ControlDock> createState() => _ControlDockState();
}

class _ControlDockState extends State<ControlDock> {
  bool _isExpanded = false;
  int _activeTabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final collapsedHeight = 24.0 + bottomPadding;
    final expandedHeight = 490.0 + bottomPadding;

    return GestureDetector(
      onVerticalDragUpdate: _handleVerticalDragUpdate,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.fastOutSlowIn,
        width: double.infinity,
        height: _isExpanded ? expandedHeight : collapsedHeight,
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(32),
            topRight: Radius.circular(32),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: EdgeInsets.fromLTRB(24, 8, 24, _isExpanded ? 16 + bottomPadding : bottomPadding + 4),
              decoration: BoxDecoration(
                color: const Color(0xFF0F111A).withValues(alpha: 0.85),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(32),
                  topRight: Radius.circular(32),
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 20,
                    spreadRadius: 2,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag Handle Area
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      margin: EdgeInsets.only(top: 4, bottom: _isExpanded ? 16 : 0),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                  
                  // Content switcher based on expansion state
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: _isExpanded 
                        ? _buildExpandedContent() 
                        : _buildCollapsedContent(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (details.primaryDelta! < -4 && !_isExpanded) {
      setState(() {
        _isExpanded = true;
      });
    } else if (details.primaryDelta! > 4 && _isExpanded) {
      setState(() {
        _isExpanded = false;
      });
    }
  }

  // Collapsed UI
  Widget _buildCollapsedContent() {
    return const SizedBox(
      key: ValueKey('collapsed'),
    );
  }

  // Expanded UI
  Widget _buildExpandedContent() {
    return Column(
      key: const ValueKey('expanded'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Tab Bar Selection
        _buildTabBar(),
        const SizedBox(height: 20),
        // Tab Views
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _buildActiveTabContent(),
          ),
        ),
        const SizedBox(height: 8),
        // A mini-status indicator at bottom of expanded dock
        Center(
          child: Text(
            'SWIPE DOWN TO CLOSE PANEL',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: Colors.white.withValues(alpha: 0.25),
              letterSpacing: 2.0,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _buildTabItem(0, 'Start', Icons.rocket_launch_rounded),
          _buildTabItem(1, 'Elements', Icons.layers_rounded),
          _buildTabItem(2, 'Advance', Icons.tune_rounded),
        ],
      ),
    );
  }

  Widget _buildTabItem(int index, String label, IconData icon) {
    final isSelected = _activeTabIndex == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            _activeTabIndex = index;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: isSelected
                ? LinearGradient(
                    colors: [
                      Colors.cyan.withValues(alpha: 0.2),
                      Colors.blueAccent.withValues(alpha: 0.1),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            border: isSelected
                ? Border.all(color: Colors.cyanAccent.withValues(alpha: 0.4), width: 1)
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? Colors.cyanAccent : Colors.white54,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white54,
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveTabContent() {
    switch (_activeTabIndex) {
      case 0:
        return _buildStartTab();
      case 1:
        return _buildElementsTab();
      case 2:
        return _buildAdvanceTab();
      default:
        return Container();
    }
  }

  Widget _buildStartTab() {
    return Column(
      key: const ValueKey('tab_start'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(height: 8),
        _buildActionBtn(
          label: widget.isRecording ? 'Stop' : 'Record',
          icon: widget.isRecording ? Icons.stop_rounded : Icons.fiber_manual_record_rounded,
          backgroundColor: widget.isRecording ? const Color(0xFFD32F2F) : const Color(0xFF00E676),
          textColor: Colors.white,
          onPressed: widget.onRecordPressed,
        ),
        const SizedBox(height: 12),
        _buildActionBtn(
          label: 'Facebook Live',
          icon: Icons.facebook_rounded,
          backgroundColor: const Color(0xFF1877F2), // Solid Facebook blue
          textColor: Colors.white,
          onPressed: () {},
        ),
        const SizedBox(height: 12),
        _buildActionBtn(
          label: 'YouTube Live',
          icon: Icons.play_arrow_rounded,
          backgroundColor: const Color(0xFFFF0000), // Solid YouTube red
          textColor: Colors.white,
          onPressed: () {},
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildActionBtn({
    required String label,
    required IconData icon,
    required Color backgroundColor,
    required Color textColor,
    required VoidCallback onPressed,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          splashColor: Colors.white.withValues(alpha: 0.25),
          highlightColor: Colors.white.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: textColor,
                  size: 22,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: textColor.withValues(alpha: 0.7),
                  size: 14,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildElementsTab() {
    return Column(
      key: const ValueKey('tab_elements'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInfoCard(
          title: 'HUD OVERLAYS & GRAPHICS',
          subtitle: 'Customize user-facing layouts and guides.',
          icon: Icons.grid_view_rounded,
          accentColor: Colors.purpleAccent,
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            children: [
              _buildSettingRow(
                title: 'Rule of Thirds Grid',
                value: 'Enabled',
                icon: Icons.grid_on_rounded,
              ),
              _buildSettingRow(
                title: 'PiP Mirroring',
                value: 'Standard',
                icon: Icons.flip_rounded,
              ),
              _buildSettingRow(
                title: 'Color Grading Filter',
                value: 'Cyberpunk Teal',
                icon: Icons.color_lens_outlined,
              ),
              _buildSettingRow(
                title: 'Telemetry Guide Lines',
                value: 'Safe Zone 16:9',
                icon: Icons.aspect_ratio_rounded,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAdvanceTab() {
    return Padding(
      key: const ValueKey('tab_advance'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildEdgeLightSection(),
          if (widget.isPiPMode) ...[
            const SizedBox(height: 12),
            _buildPiPSection(),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: accentColor,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: accentColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEdgeLightSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF0D0).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.ring_volume_rounded, color: Color(0xFFFFF0D0), size: 18),
              ),
              const SizedBox(width: 12),
              const Text(
                'EDGE LIGHT',
                style: TextStyle(
                  color: Color(0xFFFFF0D0),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.4,
                ),
              ),
              const Spacer(),
              Switch(
                value: widget.isEdgeLightOn,
                onChanged: widget.onEdgeLightChanged,
                activeThumbColor: const Color(0xFFFFF0D0),
                activeTrackColor: const Color(0xFFFFF0D0).withValues(alpha: 0.4),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPiPSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.cyan.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.cyanAccent, size: 18),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'PiP CONTROL',
                    style: TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildSliderRow(
                label: 'Border Radius',
                value: widget.pipCornerRadius.toInt().toString(),
                min: 0, max: 30,
                current: widget.pipCornerRadius,
                divisions: 30,
                onChanged: (v) => widget.onPipCornerRadiusChanged(v),
              ),
              const SizedBox(height: 8),
              _buildSliderRow(
                label: 'Shadow Amount',
                value: widget.pipShadowAlpha.toString(),
                min: 0, max: 255,
                current: widget.pipShadowAlpha.toDouble(),
                divisions: 51,
                onChanged: (v) => widget.onPipShadowAlphaChanged(v.round()),
              ),
              const SizedBox(height: 8),
              _buildSliderRow(
                label: 'PiP Zoom',
                value: '${widget.pipZoom.toStringAsFixed(1)}x',
                min: 1.0, max: 3.0,
                current: widget.pipZoom,
                divisions: 40,
                onChanged: (v) => widget.onPipZoomChanged(v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSliderRow({
    required String label,
    required String value,
    required double min,
    required double max,
    required double current,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w500),
            ),
            Text(
              value,
              style: const TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        Slider(
          value: current.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: Colors.cyanAccent,
          inactiveColor: Colors.white.withValues(alpha: 0.1),
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildSettingRow({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.03)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: Colors.white38,
                size: 18,
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.cyanAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

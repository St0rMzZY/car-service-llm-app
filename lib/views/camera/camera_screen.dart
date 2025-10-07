// lib/views/camera/camera_screen.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;

import 'pdf_preview_screen.dart'; // adjust path if needed

Uint8List _processImageIsolate(Map<String, dynamic> args) {
  final Uint8List bytes = args['bytes'] as Uint8List;
  final int targetWidth = args['targetWidth'] as int;
  final int quality = args['quality'] as int;

  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  final img.Image resized = (decoded.width > targetWidth)
      ? img.copyResize(decoded, width: targetWidth)
      : decoded;

  final List<int> out = img.encodeJpg(resized, quality: quality);
  return Uint8List.fromList(out);
}

class CameraScreen extends StatefulWidget {
  final List<CameraDescription>? cameras;
  final bool returnCapturedPath;

  const CameraScreen({
    super.key,
    this.cameras,
    this.returnCapturedPath = false,
  });

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;
  final Logger _log = Logger('CameraScreen');
  bool _isInitialized = false;
  bool _isProcessing = false;
  int _cameraIndex = 0;

  // Animation & UI state
  late final AnimationController _focusAnimationController;
  late final Animation<double> _focusAnimation;
  bool _isShutterButtonPressed = false;

  // Zoom & focus state
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _baseZoom = 1.0;

  bool _showFocus = false;
  Offset _focusPoint = Offset.zero;

  // preview key to compute sizes for tap-to-focus
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Go fully immersive
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _focusAnimationController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
    _focusAnimation =
        CurvedAnimation(parent: _focusAnimationController, curve: Curves.easeOut);

    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    final cams = widget.cameras ?? [];
    if (cams.isEmpty) {
      _log.warning('No cameras available.');
      if (mounted) setState(() => _isInitialized = true);
      return;
    }
    final desc = cams[_cameraIndex % cams.length];
    await _controller?.dispose();
    _controller = CameraController(
      desc,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await _controller!.initialize();

      // fetch zoom bounds
      try {
        _minZoom = await _controller!.getMinZoomLevel();
        _maxZoom = await _controller!.getMaxZoomLevel();
        _currentZoom = _currentZoom.clamp(_minZoom, _maxZoom);
        await _controller!.setZoomLevel(_currentZoom);
      } catch (_) {
        // ignore if not supported
      }
    } catch (e, st) {
      _log.severe('Camera init error: $e\n$st');
    }
    if (!mounted) return;
    setState(() => _isInitialized = true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_controller == null) return;
    if (state == AppLifecycleState.inactive) {
      await _controller!.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      await _initializeCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Restore system UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    _focusAnimationController.dispose();
    _controller?.dispose();
    super.dispose();
  }

  Future<String> _writeBytesToTemp(Uint8List bytes, String ext) async {
    final tmp = await getTemporaryDirectory();
    final path = p.join(
      tmp.path,
      'img_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    final f = File(path);
    await f.writeAsBytes(bytes, flush: true);
    return path;
  }

  Future<void> _takePicture() async {
    if (_isProcessing) return;

    HapticFeedback.lightImpact(); // Haptic feedback for shutter
    setState(() => _isProcessing = true);

    try {
      final perm = await Permission.camera.request();
      if (!perm.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera permission required')),
          );
        }
        return;
      }
      final c = _controller;
      if (c == null || !c.value.isInitialized) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Camera not available')));
        }
        return;
      }
      if (c.value.isTakingPicture) return;

      final XFile raw = await c.takePicture();
      final bytes = await File(raw.path).readAsBytes();

      Uint8List processed = await compute(_processImageIsolate, {
        'bytes': bytes,
        'targetWidth': 1200,
        'quality': 70,
      });

      final ext =
          p.extension(raw.path).isNotEmpty ? p.extension(raw.path) : '.jpg';
      final processedPath = await _writeBytesToTemp(processed, ext);

      if (!mounted) return;

      if (widget.returnCapturedPath) {
        Navigator.of(context).pop(processedPath);
        return;
      }

      final result = await Navigator.of(context).push<Map<String, String>?>(
        MaterialPageRoute(
          builder: (_) => PdfPreviewScreen(initialImages: [processedPath]),
        ),
      );

      if (result != null && result.containsKey('localPath')) {
        Navigator.of(context).pop(result);
      } else {
        // Re-initialize camera if user discards the preview
        await _initializeCamera();
      }
    } catch (e, st) {
      _log.severe('Error capture: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _onTapToFocus(TapDownDetails details) async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    final RenderBox? box =
        _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.globalPosition);
    final size = box.size;

    final dx = (local.dx / size.width).clamp(0.0, 1.0);
    final dy = (local.dy / size.height).clamp(0.0, 1.0);
    final normalized = Offset(dx, dy);

    try {
      await _controller!.setExposurePoint(normalized);
      await _controller!.setFocusPoint(normalized);
      await _controller!.setFocusMode(FocusMode.auto);
    } catch (e) {
      // ignore if not supported
    }

    setState(() {
      _focusPoint = normalized;
      _showFocus = true;
    });

    _focusAnimationController.forward(from: 0.0);

    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showFocus = false);
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseZoom = _currentZoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_controller == null) return;
    final newZoom = (_baseZoom * details.scale).clamp(_minZoom, _maxZoom);
    try {
      _controller!.setZoomLevel(newZoom);
    } catch (_) {}
    setState(() => _currentZoom = newZoom);
  }

  Widget _buildTopBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const Text(
                'ServiScribe',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(blurRadius: 2.0)],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                onPressed: () async {
                  HapticFeedback.lightImpact();
                  final cams = widget.cameras ?? [];
                  if (cams.length < 2) return;
                  _cameraIndex = (_cameraIndex + 1) % cams.length;
                  setState(() => _isInitialized = false);
                  await _initializeCamera();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Container(
          height: 110,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.photo_library,
                    color: Colors.white, size: 30),
                onPressed: () {
                  /* placeholder */
                },
              ),
              GestureDetector(
                onTapDown: (_) =>
                    setState(() => _isShutterButtonPressed = true),
                onTapUp: (_) =>
                    setState(() => _isShutterButtonPressed = false),
                onTapCancel: () =>
                    setState(() => _isShutterButtonPressed = false),
                onTap: _takePicture,
                child: AnimatedScale(
                  scale: _isShutterButtonPressed ? 0.9 : 1.0,
                  duration: const Duration(milliseconds: 100),
                  child: Container(
                    height: 72,
                    width: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.transparent,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 48), // To balance the row
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildZoomSlider() {
    if (_minZoom == _maxZoom) return const SizedBox.shrink();
    return Positioned(
      right: 8,
      bottom: 120,
      child: RotatedBox(
        quarterTurns: -1,
        child: Container(
          width: 140,
          decoration: BoxDecoration(
            color: Colors.black38,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Slider(
            value: _currentZoom,
            min: _minZoom,
            max: _maxZoom,
            onChanged: (v) async {
              try {
                await _controller?.setZoomLevel(v);
              } catch (_) {}
              setState(() => _currentZoom = v);
            },
            activeColor: Colors.white,
            inactiveColor: Colors.white30,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized ||
        _controller == null ||
        !_controller!.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera Preview
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onTapDown: _onTapToFocus,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Get the screen's aspect ratio (width/height)
                final screenAspectRatio =
                    constraints.maxWidth / constraints.maxHeight;

                // Get the camera's reported aspect ratio (width/height)
                var previewAspectRatio = _controller!.value.aspectRatio;

                // ** THE FIX IS HERE **
                // If the screen is in portrait mode and the camera is reporting a
                // landscape aspect ratio, we invert it to match.
                if (screenAspectRatio < 1 && previewAspectRatio > 1) {
                  previewAspectRatio = 1 / previewAspectRatio;
                }
                
                return FittedBox(
                  fit: BoxFit.cover,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxWidth / previewAspectRatio,
                    child: Container(
                      key: _previewKey,
                      child: CameraPreview(_controller!),
                    ),
                  ),
                );
              },
            ),
          ),

          // Animated Focus Indicator
          if (_showFocus)
            LayoutBuilder(
              builder: (context, constraints) {
                final left = _focusPoint.dx * constraints.maxWidth;
                final top = _focusPoint.dy * constraints.maxHeight;
                return Positioned(
                  left: left - 36,
                  top: top - 36,
                  child: FadeTransition(
                    opacity: _focusAnimation,
                    child: ScaleTransition(
                      scale: _focusAnimation,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),

          // Top and Bottom UI Overlays
          Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [_buildTopBar(), _buildBottomBar()],
          ),

          _buildZoomSlider(),
        ],
      ),
    );
  }
}
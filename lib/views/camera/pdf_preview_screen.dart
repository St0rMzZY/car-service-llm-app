// lib/views/camera/pdf_preview_screen.dart
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:camera/camera.dart';
import 'camera_screen.dart'; // local import - ensure path is correct

class PdfPreviewScreen extends StatefulWidget {
  final List<String> initialImages;

  const PdfPreviewScreen({super.key, required this.initialImages});

  @override
  State<PdfPreviewScreen> createState() => _PdfPreviewScreenState();
}

class _PdfPreviewScreenState extends State<PdfPreviewScreen> {
  late List<String> _images;
  int _activeIndex = 0;
  bool _isSaving = false;

  // Target PDF size (keep <= 90KB)
  static const int _pdfMaxBytes = 90 * 1024;

  @override
  void initState() {
    super.initState();
    _images = List<String>.from(widget.initialImages);
  }

  Future<void> _cropActiveImage() async {
    if (_images.isEmpty) return;
    final path = _images[_activeIndex];
    try {
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: path,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop',
            toolbarColor: const Color(0xFF00529B),
            toolbarWidgetColor: Colors.white,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
          IOSUiSettings(title: 'Crop'),
        ],
      );

      if (croppedFile != null && mounted) {
        setState(() {
          _images[_activeIndex] = croppedFile.path;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Crop failed: $e')));
      }
    }
  }

  // Open the in-app CameraScreen to retake the current image
  Future<void> _retakeUsingInAppCamera() async {
    try {
      final cams = await availableCameras();
      final capturedPath = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => CameraScreen(cameras: cams, returnCapturedPath: true),
        ),
      );
      if (capturedPath != null && mounted) {
        setState(() {
          _images[_activeIndex] = capturedPath;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Retake failed: $e')));
      }
    }
  }

  // Add more using in-app camera
  Future<void> _addMoreImageFromCamera() async {
    try {
      final cams = await availableCameras();
      final newPath = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => CameraScreen(cameras: cams, returnCapturedPath: true),
        ),
      );
      if (newPath != null && mounted) {
        setState(() {
          _images.add(newPath);
          _activeIndex = _images.length - 1;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Add image failed: $e')));
      }
    }
  }

  Future<String> _compressToTarget(File input, int perImageTarget) async {
    final tmp = await getTemporaryDirectory();
    final baseName = p.basename(input.path);
    final outPath = p.join(tmp.path, 'cmp_$baseName');

    final inBytes = await input.readAsBytes();
    if (inBytes.lengthInBytes <= perImageTarget) {
      final outFile = File(outPath);
      await outFile.writeAsBytes(inBytes);
      return outFile.path;
    }

    int quality = 80;
    int minQuality = 20;
    int maxWidth = 1200;
    int minWidth = 600;

    try {
      for (
        ;
        quality >= minQuality;
        quality -= 10, maxWidth = max(minWidth, (maxWidth * 0.8).round())
      ) {
        final result = await FlutterImageCompress.compressWithFile(
          input.path,
          quality: quality,
          minWidth: maxWidth,
          keepExif: false,
        );
        if (result == null) continue;
        if (result.lengthInBytes <= perImageTarget ||
            (quality == minQuality && maxWidth == minWidth)) {
          final outFile = File(outPath);
          await outFile.writeAsBytes(result);
          return outFile.path;
        }
      }
    } catch (_) {}

    try {
      final aggressive = await FlutterImageCompress.compressWithFile(
        input.path,
        quality: 15,
        minWidth: 600,
        keepExif: false,
      );
      if (aggressive != null) {
        final outFile = File(outPath);
        await outFile.writeAsBytes(aggressive);
        return outFile.path;
      }
    } catch (_) {}

    final fallback = File(outPath);
    await fallback.writeAsBytes(inBytes);
    return fallback.path;
  }

  Future<void> _savePdf() async {
    final nameController = TextEditingController(
      text: 'Scanned_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    final typed = await showDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Name PDF'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(hintText: 'Enter PDF file name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(nameController.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (typed == null || typed.isEmpty) return;

    setState(() => _isSaving = true);

    try {
      final int imageCount = max(1, _images.length);
      final int perImageTarget = max(8 * 1024, (_pdfMaxBytes ~/ imageCount));

      final List<String> compressedPaths = [];
      for (final imgPath in _images) {
        final inFile = File(imgPath);
        final cmpPath = await _compressToTarget(inFile, perImageTarget);
        compressedPaths.add(cmpPath);
      }

      PdfDocument document = PdfDocument();
      for (final cmpPath in compressedPaths) {
        final bytes = await File(cmpPath).readAsBytes();
        final PdfBitmap bitmap = PdfBitmap(bytes);
        final PdfPage page = document.pages.add();
        final Size pageSize = page.getClientSize();
        final double imgW = bitmap.width.toDouble();
        final double imgH = bitmap.height.toDouble();
        double drawW = pageSize.width;
        double drawH = imgH * (drawW / imgW);
        if (drawH > pageSize.height) {
          drawH = pageSize.height;
          drawW = imgW * (drawH / imgH);
        }
        final double x = (pageSize.width - drawW) / 2;
        final double y = (pageSize.height - drawH) / 2;
        page.graphics.drawImage(bitmap, Rect.fromLTWH(x, y, drawW, drawH));
      }

      List<int> pdfBytes = await document.save();
      document.dispose();

      // If still too large, attempt aggressive recompress & rebuild
      if (pdfBytes.length > _pdfMaxBytes) {
        final aggressivePerImage = max(6 * 1024, (_pdfMaxBytes ~/ imageCount));
        final List<String> aggressivePaths = [];
        for (final imgPath in _images) {
          final inFile = File(imgPath);
          final cmpPath = await _compressToTarget(inFile, aggressivePerImage);
          aggressivePaths.add(cmpPath);
        }

        final PdfDocument doc2 = PdfDocument();
        for (final cmpPath in aggressivePaths) {
          final bytes = await File(cmpPath).readAsBytes();
          final PdfBitmap bitmap = PdfBitmap(bytes);
          final PdfPage page = doc2.pages.add();
          final Size pageSize = page.getClientSize();
          final double imgW = bitmap.width.toDouble();
          final double imgH = bitmap.height.toDouble();
          double drawW = pageSize.width;
          double drawH = imgH * (drawW / imgW);
          if (drawH > pageSize.height) {
            drawH = pageSize.height;
            drawW = imgW * (drawH / imgH);
          }
          final double x = (pageSize.width - drawW) / 2;
          final double y = (pageSize.height - drawH) / 2;
          page.graphics.drawImage(bitmap, Rect.fromLTWH(x, y, drawW, drawH));
        }
        final List<int> pdfBytes2 = await doc2.save();
        doc2.dispose();

        if (pdfBytes2.length <= pdfBytes.length) {
          pdfBytes = pdfBytes2;
        }
      }

      final Directory tmp = await getTemporaryDirectory();
      final safeName = typed.endsWith('.pdf') ? typed : '$typed.pdf';
      final outPath = p.join(tmp.path, safeName);
      final outFile = File(outPath);
      await outFile.writeAsBytes(pdfBytes);

      final Map<String, String> result = {
        'localPath': outPath,
        'name': safeName,
      };
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save PDF: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _thumb(String path, int i) {
    return GestureDetector(
      onTap: () => setState(() => _activeIndex = i),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        width: 70,
        height: 100,
        decoration: BoxDecoration(
          border: Border.all(
            color: _activeIndex == i ? Colors.blue : Colors.grey.shade300,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(File(path), fit: BoxFit.cover),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = _images.isEmpty ? null : _images[_activeIndex];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        backgroundColor: const Color(0xFF00529B),
        actions: [
          TextButton.icon(
            onPressed: _isSaving ? null : _savePdf,
            icon: const Icon(Icons.save, color: Colors.white),
            label: _isSaving
                ? const Text('Saving...', style: TextStyle(color: Colors.white))
                : const Text('Save PDF', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: current == null
                  ? const Text('No image')
                  : Image.file(File(current), fit: BoxFit.contain),
            ),
          ),
          SizedBox(
            height: 120,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                ...List.generate(_images.length, (i) => _thumb(_images[i], i)),
                GestureDetector(
                  onTap: _addMoreImageFromCamera,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 70,
                    height: 100,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: Colors.grey.shade200,
                    ),
                    child: const Center(child: Icon(Icons.add_a_photo)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  onPressed: _cropActiveImage,
                  icon: const Icon(Icons.crop),
                  label: const Text('Crop'),
                ),
                ElevatedButton.icon(
                  onPressed: _retakeUsingInAppCamera,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Retake'),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    if (_images.isNotEmpty) {
                      setState(() {
                        _images.removeAt(_activeIndex);
                        if (_images.isEmpty) {
                          _activeIndex = 0;
                        } else {
                          _activeIndex = _activeIndex.clamp(
                            0,
                            _images.length - 1,
                          );
                        }
                      });
                    }
                  },
                  icon: const Icon(Icons.delete),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

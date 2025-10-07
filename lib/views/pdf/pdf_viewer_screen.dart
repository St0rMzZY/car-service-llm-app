import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

class PdfViewerScreen extends StatelessWidget {
  final String title;
  final String? localPath;
  final String? url;

  const PdfViewerScreen({
    super.key,
    required this.title,
    this.localPath,
    this.url,
  });

  @override
  Widget build(BuildContext context) {
    final canUseLocal = localPath != null && localPath!.isNotEmpty && File(localPath!).existsSync();
    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        backgroundColor: const Color.fromARGB(255, 4, 67, 153),
        foregroundColor: Colors.white,
      ),
      body: canUseLocal
          ? SfPdfViewer.file(File(localPath!))
          : (url != null
              ? SfPdfViewer.network(url!)
              : const Center(child: Text('No PDF source'))),
    );
  }
}

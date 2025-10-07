import 'package:flutter/foundation.dart';
import 'dart:collection';
import '../services/api_service.dart';

class PdfFile {
  final String id;
  final String path; // local path (empty for remote)
  final String name;
  final String? s3Url;
  final String? s3Key;

  PdfFile({
    required this.id,
    required this.path,
    required this.name,
    this.s3Url,
    this.s3Key,
  });

  factory PdfFile.fromJson(Map<String, dynamic> json) {
    return PdfFile(
      id: (json['id'] ?? json['file_id'] ?? '').toString(),
      name: (json['file_name'] ?? json['name'] ?? '').toString(),
      // prefer provided path if exists; default to empty for remote
      path: (json['path'] ?? '')?.toString() ?? '',
      s3Url: (json['s3_url'] ?? json['s3Url'])?.toString(),
      s3Key: (json['s3_key'] ?? json['s3Key'])?.toString(),
    );
  }

  PdfFile copyWith({
    String? id,
    String? path,
    String? name,
    String? s3Url,
    String? s3Key,
  }) {
    return PdfFile(
      id: id ?? this.id,
      path: path ?? this.path,
      name: name ?? this.name,
      s3Url: s3Url ?? this.s3Url,
      s3Key: s3Key ?? this.s3Key,
    );
  }
}

class PdfProvider with ChangeNotifier {
  List<PdfFile> _recentPdfs = [];
  bool _isLoading = false;

  UnmodifiableListView<PdfFile> get recentPdfs =>
      UnmodifiableListView(_recentPdfs);
  bool get isLoading => _isLoading;

  Future<void> fetchRecentPdfs(String userEmail) async {
    _isLoading = true;
    notifyListeners();
    try {
      final raw = await ApiService.listFiles(userEmail); // List<dynamic>
      _recentPdfs = (raw as List<dynamic>)
          .map((e) => PdfFile.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print("Error fetching recent PDFs: $e");
      }
      _recentPdfs = [];
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Add or update a pdf in the in-memory recent list.
  /// Match by id (preferred) then by s3Key then by name (fallback).
  void addPdf(PdfFile pdf) {
    final existingIndex = _recentPdfs.indexWhere((p) {
      if (pdf.id.isNotEmpty && p.id.isNotEmpty) return p.id == pdf.id;
      if (pdf.s3Key != null &&
          pdf.s3Key!.isNotEmpty &&
          p.s3Key != null &&
          p.s3Key!.isNotEmpty) {
        return p.s3Key == pdf.s3Key;
      }
      return p.name == pdf.name;
    });

    if (existingIndex >= 0) {
      final existing = _recentPdfs[existingIndex];
      // build merged PdfFile (do not mutate existing)
      final merged = existing.copyWith(
        id: pdf.id.isNotEmpty ? pdf.id : existing.id,
        path: pdf.path.isNotEmpty ? pdf.path : existing.path,
        name: pdf.name.isNotEmpty ? pdf.name : existing.name,
        s3Url: pdf.s3Url ?? existing.s3Url,
        s3Key: pdf.s3Key ?? existing.s3Key,
      );
      // move to top
      _recentPdfs.removeAt(existingIndex);
      _recentPdfs.insert(0, merged);
    } else {
      // newest first
      _recentPdfs.insert(0, pdf);
    }
    notifyListeners();
  }

  void removePdfById(String id) {
    _recentPdfs.removeWhere((p) => p.id == id);
    notifyListeners();
  }

  Future<void> deletePdf(String fileId) async {
    try {
      await ApiService.deletePdf(fileId);
      removePdfById(fileId);
    } catch (e) {
      if (kDebugMode) {
        print("Error deleting PDF: $e");
      }
    }
  }
}

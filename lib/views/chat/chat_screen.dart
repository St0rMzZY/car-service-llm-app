// lib/views/chat/chat_screen.dart
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../models/chat_message.dart';
import '../../providers/pdf_provider.dart';
import '../../providers/chat_history_provider.dart';
import '../../services/api_service.dart';
import 'package:path/path.dart' as p;
import '../camera/camera_screen.dart';
import '../camera/pdf_preview_screen.dart';
import '../pdf/pdf_viewer_screen.dart';
import '../home/home_screen.dart';

class ChatScreen extends StatefulWidget {
  final PdfFile? pdfFile;
  final ChatConversation? conversation;
  final List<CameraDescription>? cameras;
  final String? s3Key;
  final String? fileId;
  final String? fileName;

  const ChatScreen({
    super.key,
    this.pdfFile,
    this.conversation,
    this.cameras,
    this.s3Key,
    this.fileId,
    this.fileName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  List<ChatMessage> _messages = [];
  PdfFile? _activePdf;
  bool _isLoading = false;
  String? _conversationId;

  String? _selectedLlm;
  final List<String> _llmOptions = ['Claude'];

  @override
  void initState() {
    super.initState();

    if (widget.conversation != null) {
      _conversationId = widget.conversation!.id;
      _messages = List.from(widget.conversation!.messages);
      final s3Url = widget.conversation!.s3Url;
      if (s3Url != null) {
        _activePdf = PdfFile(
          id: '',
          path: '',
          name: 'Previous Document',
          s3Url: s3Url,
          s3Key: widget.conversation!.s3Key,
        );
      }
      return;
    }

    if (widget.pdfFile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final file = widget.pdfFile!;
        if (file.path.isNotEmpty) {
          _startNewChatWithPdf(file);
        } else {
          _openRemotePdfAsChat(file);
        }
      });
      return;
    }

    if ((widget.s3Key != null && widget.s3Key!.isNotEmpty) ||
        (widget.fileId != null && widget.fileId!.isNotEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pdf = PdfFile(
          id: widget.fileId ?? '',
          path: '',
          name: widget.fileName ?? 'Remote PDF',
          s3Url: null,
          s3Key: widget.s3Key,
        );
        _openRemotePdfAsChat(pdf);
      });
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _goHome() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => HomeScreen(cameras: widget.cameras ?? []),
      ),
    );
  }

  /// Try to resolve a presigned URL for the uploaded PDF using listFiles.
  Future<void> _ensurePdfHasPresignedUrl(PdfFile uploadedPdf) async {
    if ((uploadedPdf.s3Url?.isNotEmpty ?? false)) return;
    try {
      final files = await ApiService.listFiles("test@example.com");
      for (final f in files) {
        final map = f as Map<String, dynamic>;
        final id = (map['id'] ?? map['file_id'])?.toString();
        final key = (map['s3_key'] ?? map['s3Key'])?.toString();
        final presigned = (map['s3_url'] ?? map['s3Url'])?.toString();
        if ((uploadedPdf.id.isNotEmpty && id == uploadedPdf.id) ||
            (uploadedPdf.s3Key != null && key == uploadedPdf.s3Key)) {
          if (presigned != null && presigned.isNotEmpty) {
            if (!mounted) return;
            setState(() {
              _activePdf =
                  _activePdf?.copyWith(s3Url: presigned) ??
                  uploadedPdf.copyWith(s3Url: presigned);
            });
          }
          break;
        }
      }
    } catch (_) {
      // ignore resolution errors
    }
  }

  Future<void> _startNewChatWithPdf(PdfFile file) async {
    setState(() {
      _isLoading = true;
      _activePdf = file;
      _messages.clear();
      _conversationId = null;
      _messages.add(
        ChatMessage(
          type: MessageType.fileInfo,
          title: 'Uploaded File',
          content: file.name,
        ),
      );
    });

    const userEmail = "test@example.com";
    // capture providers before async work
    final pdfProvider = Provider.of<PdfProvider>(context, listen: false);
    final chatHistoryProvider = Provider.of<ChatHistoryProvider>(
      context,
      listen: false,
    );

    try {
      if (file.path.isNotEmpty) {
        final Map<String, dynamic> res = await ApiService.processDocument(
          file.path,
          userEmail,
        );

        final s3Url = (res['s3_url'] ?? res['s3Url']) as String?;
        final s3Key = (res['s3_key'] ?? res['s3Key']) as String?;
        final fileId = (res['file_id'] ?? res['fileId'])?.toString();
        final fileName =
            (res['file_name'] ?? res['fileName']) as String? ?? file.name;

        final uploadedPdf = PdfFile(
          id: fileId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          path: '',
          name: fileName,
          s3Url: s3Url,
          s3Key: s3Key,
        );

        if (!mounted) {
          _activePdf = uploadedPdf;
          return;
        }
        setState(() => _activePdf = uploadedPdf);

        // add to provider and try to resolve presigned url for immediate viewing
        pdfProvider.addPdf(uploadedPdf);
        try {
          await pdfProvider.fetchRecentPdfs(userEmail);
        } catch (_) {}

        // attempt to resolve presigned url immediately if backend returned none
        await _ensurePdfHasPresignedUrl(uploadedPdf);

        // If server returned conversation/messages, show them
        final convFromProcess =
            (res['conversation_id'] ?? res['conversationId'])?.toString();
        if (convFromProcess != null && convFromProcess.isNotEmpty) {
          if (!mounted) return;
          final returnedMessages =
              (res['messages'] as List<dynamic>?) ??
              (res['Messages'] as List<dynamic>?);
          if (returnedMessages != null && returnedMessages.isNotEmpty) {
            final mapped = returnedMessages
                .map(
                  (m) => ChatMessage(
                    type: MessageType.reply,
                    title: 'Reply',
                    content: (m['answer'] ?? m['answerText'] ?? '').toString(),
                  ),
                )
                .toList();
            setState(() {
              _conversationId = convFromProcess;
              _messages = mapped;
            });
          } else {
            if (!mounted) return;
            setState(() => _conversationId = convFromProcess);
          }
          return;
        }

        // Otherwise attempt to create a chat record on server using s3_key (preferred) or s3_url
        try {
          final created = await chatHistoryProvider.createChatWithPdf(
            title: uploadedPdf.name,
            pdfId: uploadedPdf.id,
            pdfS3Url: uploadedPdf.s3Url,
            pdfS3Key: uploadedPdf.s3Key,
            initiatedByEmail: userEmail,
          );

          if (created != null) {
            if (!mounted) return;
            setState(() {
              _conversationId = created.id;
              _messages = List.from(created.messages);
              _activePdf =
                  _activePdf?.copyWith(
                    s3Url: created.s3Url ?? _activePdf?.s3Url,
                    s3Key: created.s3Key ?? _activePdf?.s3Key,
                  ) ??
                  _activePdf;
            });
          } else {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Created chat failed on server. You can still use the PDF locally.',
                ),
              ),
            );
          }

          // after createChatWithPdf, attempt presigned resolution one more time
          if (!mounted) return;
          await _ensurePdfHasPresignedUrl(_activePdf ?? uploadedPdf);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Server chat creation failed. You can continue locally.',
              ),
            ),
          );
        }
      } else {
        pdfProvider.addPdf(file);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error processing document: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _attachPdfToExistingChat(PdfFile file) async {
    setState(() {
      _isLoading = true;
      _messages.add(
        ChatMessage(
          type: MessageType.fileInfo,
          title: 'Uploaded File',
          content: file.name,
        ),
      );
    });

    const userEmail = "test@example.com";
    final pdfProvider = Provider.of<PdfProvider>(context, listen: false);

    try {
      if (file.path.isNotEmpty) {
        final Map<String, dynamic> res = await ApiService.processDocument(
          file.path,
          userEmail,
        );
        final s3Url = (res['s3_url'] ?? res['s3Url']) as String?;
        final s3Key = (res['s3_key'] ?? res['s3Key']) as String?;
        final fileId = (res['file_id'] ?? res['fileId'])?.toString();
        final fileName =
            (res['file_name'] ?? res['fileName']) as String? ?? file.name;

        final uploadedPdf = PdfFile(
          id: fileId ?? DateTime.now().millisecondsSinceEpoch.toString(),
          path: '',
          name: fileName,
          s3Url: s3Url,
          s3Key: s3Key,
        );

        if (!mounted) {
          _activePdf = uploadedPdf;
          return;
        }
        setState(() => _activePdf = uploadedPdf);

        pdfProvider.addPdf(uploadedPdf);
        try {
          await pdfProvider.fetchRecentPdfs(userEmail);
        } catch (_) {}

        // resolve presigned url so user can open immediately
        await _ensurePdfHasPresignedUrl(uploadedPdf);

        if (_conversationId != null) {
          try {
            // Prefer calling backend create-chat with s3_key first
            await ApiService.createChat({
              'title': _activePdf?.name ?? 'Attach PDF',
              'pdf_id': uploadedPdf.id,
              's3_key': uploadedPdf.s3Key,
              'pdf_s3_url': uploadedPdf.s3Url,
              'user_email': userEmail,
              'conversation_id': _conversationId,
            });
          } catch (_) {
            // ignore attach failure; user still has file locally
          }
        }
      } else {
        pdfProvider.addPdf(file);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error uploading additional PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result != null && result.files.single.path != null) {
      final pickedFile = result.files.single;
      final tempDir = await getTemporaryDirectory();
      final newPath = p.join(tempDir.path, pickedFile.name);
      final copiedFile = await File(pickedFile.path!).copy(newPath);
      final pdf = PdfFile(id: '', path: copiedFile.path, name: pickedFile.name);
      if (_conversationId == null) {
        await _startNewChatWithPdf(pdf);
      } else {
        await _attachPdfToExistingChat(pdf);
      }
    }
  }

  Future<void> _openCameraAndCreatePdf() async {
    final cams = widget.cameras;
    if (cams == null || cams.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No cameras available')));
      }
      return;
    }

    final imagePath = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CameraScreen(cameras: cams, returnCapturedPath: true),
      ),
    );
    if (imagePath == null) return;

    final result = await Navigator.of(context).push<Map<String, String>?>(
      MaterialPageRoute(
        builder: (_) => PdfPreviewScreen(initialImages: [imagePath]),
      ),
    );
    if (result != null && result.containsKey('localPath')) {
      final localPdfPath = result['localPath']!;
      final name = result['name'] ?? p.basename(localPdfPath);
      final pdf = PdfFile(id: '', path: localPdfPath, name: name);
      if (_conversationId == null) {
        await _startNewChatWithPdf(pdf);
      } else {
        await _attachPdfToExistingChat(pdf);
      }
    }
  }

  /// Helper: poll file-status endpoint for file readiness
  Future<bool> _waitForFileReady({
    String? fileId,
    int maxAttempts = 20,
    Duration interval = const Duration(seconds: 3),
  }) async {
    if (fileId == null || fileId.isEmpty) return false;
    for (int i = 0; i < maxAttempts; i++) {
      try {
        final statusResp = await ApiService.fileStatus(fileId);
        final status =
            (statusResp['processing_status'] ?? statusResp['status'] ?? '')
                .toString()
                .toLowerCase();
        if (status == 'completed') return true;
        if (status == 'failed') return false;
      } catch (_) {
        // transient error - ignore and retry
      }
      await Future.delayed(interval);
    }
    return false;
  }

  Future<void> _sendMessage() async {
    if (_textController.text.isEmpty || _isLoading) return;
    final query = _textController.text;
    _textController.clear();
    final llmToSend = _selectedLlm ?? _llmOptions.first;

    setState(() {
      _isLoading = true;
      _messages.add(
        ChatMessage(
          type: MessageType.query,
          title: 'Your Query',
          content: query,
        ),
      );
    });

    try {
      Map<String, dynamic>? response;
      final fileId = (_activePdf != null && _activePdf!.id.isNotEmpty)
          ? _activePdf!.id
          : null;
      int attempts = 0;
      const maxAttempts = 12;
      const waitBetweenRetries = Duration(seconds: 3);

      while (attempts < maxAttempts) {
        attempts++;
        try {
          response = await ApiService.getChatReply(
            query: query,
            userEmail: "test@example.com",
            s3Url: _activePdf?.s3Url,
            s3Key: _activePdf?.s3Key,
            llm: llmToSend,
            conversationId: _conversationId,
          );
          break; // success
        } catch (e) {
          final msg = e.toString().toLowerCase();
          if (msg.contains('425') ||
              msg.contains('document still processing') ||
              msg.contains('processing')) {
            final ok = await _waitForFileReady(
              fileId: fileId,
              maxAttempts: 10,
              interval: const Duration(seconds: 2),
            );
            if (!ok) {
              await Future.delayed(waitBetweenRetries);
              continue;
            }
            continue; // retry immediately after confirmed ready
          }
          // other error -> show as message and stop
          if (!mounted) return;
          setState(() {
            _messages.add(
              ChatMessage(
                type: MessageType.reply,
                title: 'Error',
                content: 'Failed to get reply: $e',
              ),
            );
          });
          return;
        }
      }

      if (response != null) {
        // create local-safe copies of values to avoid analyzer null-index warnings
        final convId =
            (response['conversation_id'] ?? response['conversationId'])
                ?.toString();
        final answerText =
            (response['answer'] ?? response['answerText'])?.toString() ??
            'No answer';

        _conversationId ??= convId;
        if (!mounted) return;
        setState(() {
          _messages.add(
            ChatMessage(
              type: MessageType.reply,
              title: 'Reply',
              content: answerText,
            ),
          );
        });
      } else {
        if (!mounted) return;
        setState(() {
          _messages.add(
            ChatMessage(
              type: MessageType.reply,
              title: 'Error',
              content: 'No response from server after retries.',
            ),
          );
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Open remote PDF as chat - resolve s3Key/s3Url via provider/listFiles and create chat
  Future<void> _openRemotePdfAsChat(PdfFile file) async {
    setState(() {
      _isLoading = true;
      _activePdf = file;
      _messages.clear();
      _messages.add(
        ChatMessage(
          type: MessageType.fileInfo,
          title: 'Attached File',
          content: file.name,
        ),
      );
    });

    const userEmail = "test@example.com";
    final pdfProvider = Provider.of<PdfProvider>(context, listen: false);

    try {
      // Refresh provider to get s3Url/s3Key if available
      try {
        await pdfProvider.fetchRecentPdfs(userEmail);
      } catch (_) {}

      // Try to find a matching provider entry and create a merged PdfFile
      final list = pdfProvider.recentPdfs;
      for (final pfile in list) {
        if (pfile.id.isNotEmpty && pfile.id == file.id) {
          final mergedLocal = _activePdf!.copyWith(
            s3Key: _activePdf!.s3Key ?? pfile.s3Key,
            s3Url: _activePdf!.s3Url ?? pfile.s3Url,
            id: _activePdf!.id.isNotEmpty ? _activePdf!.id : pfile.id,
          );
          _activePdf = mergedLocal;
          pdfProvider.addPdf(mergedLocal);
          break;
        }
        if (file.s3Key != null &&
            file.s3Key!.isNotEmpty &&
            pfile.s3Key == file.s3Key) {
          final mergedLocal = _activePdf!.copyWith(
            s3Key: _activePdf!.s3Key ?? pfile.s3Key,
            s3Url: _activePdf!.s3Url ?? pfile.s3Url,
            id: _activePdf!.id.isNotEmpty ? _activePdf!.id : pfile.id,
          );
          _activePdf = mergedLocal;
          pdfProvider.addPdf(mergedLocal);
          break;
        }
      }

      final s3Key = _activePdf?.s3Key ?? file.s3Key;
      final fid = file.id.isNotEmpty ? file.id : null;

      if (s3Key != null && s3Key.isNotEmpty) {
        await _ensureServerChatForS3(s3Key, fid, file.name);
      } else if (fid != null) {
        // try to resolve by listing files from API (this will return array thanks to ApiService)
        final files = await ApiService.listFiles(userEmail);
        for (final f in files) {
          final map = f as Map<String, dynamic>;
          final id = (map['id'] ?? map['file_id'])?.toString();
          if (id == fid) {
            final resolvedKey = (map['s3_key'] ?? map['s3Key'])?.toString();
            final presigned = (map['s3_url'] ?? map['s3Url'])?.toString();
            if (resolvedKey != null && resolvedKey.isNotEmpty) {
              final mergedLocal = _activePdf!.copyWith(
                s3Key: resolvedKey,
                s3Url: presigned,
              );
              _activePdf = mergedLocal;
              pdfProvider.addPdf(mergedLocal);
              await _ensureServerChatForS3(resolvedKey, fid, file.name);
            } else if (presigned != null && presigned.isNotEmpty) {
              final mergedLocal = _activePdf!.copyWith(s3Url: presigned);
              _activePdf = mergedLocal;
              pdfProvider.addPdf(mergedLocal);
            }
            break;
          }
        }
      } else {
        // fallback: if pdf already had a s3Url, attempt to create chat using it
        if (file.s3Url != null && file.s3Url!.isNotEmpty) {
          try {
            final resp = await ApiService.createChatFromS3(
              userEmail: userEmail,
              s3Key: '',
              title: file.name,
              pdfId: file.id,
              s3Url: file.s3Url,
            );
            final convId = resp['conversation_id']?.toString();
            final s3urlFromResp = (resp['s3_url'] ?? resp['s3Url'])?.toString();
            if (convId != null && convId.isNotEmpty) {
              if (!mounted) return;
              setState(() {
                _conversationId = convId;
                if (s3urlFromResp != null && s3urlFromResp.isNotEmpty) {
                  _activePdf =
                      _activePdf?.copyWith(s3Url: s3urlFromResp) ?? _activePdf;
                }
                final msg = resp['message']?.toString();
                if (msg != null && msg.isNotEmpty) {
                  _messages.add(
                    ChatMessage(
                      type: MessageType.reply,
                      title: 'Note',
                      content: msg,
                    ),
                  );
                }
              });
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create chat from remote PDF: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _ensureServerChatForS3(
    String s3Key,
    String? fileId,
    String? title,
  ) async {
    setState(() => _isLoading = true);
    const userEmail = "test@example.com";
    try {
      // prefer createChatFromS3 with s3_key
      final resp = await ApiService.createChatFromS3(
        userEmail: userEmail,
        s3Key: s3Key,
        title: title,
        pdfId: fileId,
      );
      final convId = resp['conversation_id']?.toString();
      final s3urlFromResp = (resp['s3_url'] ?? resp['s3Url'])?.toString();
      if (convId != null && convId.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _conversationId = convId;
          if (s3urlFromResp != null && s3urlFromResp.isNotEmpty) {
            _activePdf =
                _activePdf?.copyWith(s3Url: s3urlFromResp) ?? _activePdf;
          }
          final msg = resp['message']?.toString();
          if (msg != null && msg.isNotEmpty) {
            _messages.add(
              ChatMessage(type: MessageType.reply, title: 'Note', content: msg),
            );
          }
        });
        return;
      }
      throw Exception('Empty response from create-chat-from-s3');
    } catch (e) {
      final err = e.toString().toLowerCase();
      // If not ready, try to resolve fileId and poll
      if (err.contains('425') ||
          err.contains('processing') ||
          (fileId != null && fileId.isNotEmpty)) {
        final fid = fileId ?? await _tryResolveFileIdFromS3Key(s3Key);
        if (fid != null) {
          final ok = await _pollFileStatusAndRetryCreate(
            fid,
            s3Key,
            title,
            userEmail,
          );
          if (ok) return;
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Document is still processing — try again in a few seconds.',
              ),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Server chat creation failed: $e')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String?> _tryResolveFileIdFromS3Key(String s3Key) async {
    try {
      final files = await ApiService.listFiles("test@example.com");
      for (final f in files) {
        final map = f as Map<String, dynamic>;
        final key = (map['s3_key'] ?? map['s3Key'])?.toString();
        final id = (map['id'] ?? map['file_id'])?.toString();
        if (key != null && key == s3Key) return id;
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _pollFileStatusAndRetryCreate(
    String fileId,
    String s3Key,
    String? title,
    String userEmail,
  ) async {
    const interval = Duration(seconds: 3);
    const maxAttempts = 20;
    for (int i = 0; i < maxAttempts; i++) {
      try {
        final statusResp = await ApiService.fileStatus(fileId);
        final status =
            (statusResp['processing_status'] ?? statusResp['status'] ?? '')
                .toString()
                .toLowerCase();
        if (status == 'completed') {
          try {
            final resp = await ApiService.createChatFromS3(
              userEmail: userEmail,
              s3Key: s3Key,
              title: title,
              pdfId: fileId,
            );
            final convId = resp['conversation_id']?.toString();
            final serverMessages = resp['messages'] as List<dynamic>?;
            final s3urlFromResp = (resp['s3_url'] ?? resp['s3Url'])?.toString();
            if (convId != null && convId.isNotEmpty) {
              if (!mounted) return true;
              setState(() {
                _conversationId = convId;
                if (s3urlFromResp != null && s3urlFromResp.isNotEmpty) {
                  _activePdf =
                      _activePdf?.copyWith(s3Url: s3urlFromResp) ?? _activePdf;
                }
                if (serverMessages != null && serverMessages.isNotEmpty) {
                  _messages.addAll(
                    serverMessages
                        .map(
                          (m) => ChatMessage(
                            type: MessageType.reply,
                            title: 'Reply',
                            content: (m['answer'] ?? '').toString(),
                          ),
                        )
                        .toList(),
                  );
                }
              });
            }
            return true;
          } catch (_) {
            return false;
          }
        }
      } catch (_) {}
      await Future.delayed(interval);
    }
    return false;
  }

  Widget _buildMessageCard({
    required String title,
    required String content,
    required MessageType type,
  }) {
    Color cardColor;
    IconData? icon;
    switch (type) {
      case MessageType.query:
        cardColor = Colors.blue.shade50;
        break;
      case MessageType.fileInfo:
        cardColor = Colors.grey.shade100;
        icon = Icons.description_outlined;
        break;
      case MessageType.reply:
        cardColor = Colors.grey.shade100;
        break;
    }

    Widget contentWidget = Text(content, style: const TextStyle(fontSize: 16));

    final canOpen =
        (_activePdf?.s3Url != null && _activePdf!.s3Url!.isNotEmpty) ||
        (_activePdf?.path != null && _activePdf!.path.isNotEmpty);

    if (type == MessageType.fileInfo && canOpen) {
      contentWidget = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              final pdf = _activePdf;
              if (pdf == null) return;
              if (pdf.s3Url != null && pdf.s3Url!.isNotEmpty) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        PdfViewerScreen(title: pdf.name, url: pdf.s3Url),
                  ),
                );
                return;
              }
              if (pdf.path.isNotEmpty) {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        PdfViewerScreen(title: pdf.name, localPath: pdf.path),
                  ),
                );
              }
            },
            child: Row(
              children: [
                const Icon(Icons.picture_as_pdf_outlined, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    content,
                    style: const TextStyle(
                      fontSize: 16,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () {
                  final pdf = _activePdf;
                  if (pdf == null) return;
                  if (pdf.s3Url != null && pdf.s3Url!.isNotEmpty) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            PdfViewerScreen(title: pdf.name, url: pdf.s3Url),
                      ),
                    );
                    return;
                  }
                  if (pdf.path.isNotEmpty) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PdfViewerScreen(
                          title: pdf.name,
                          localPath: pdf.path,
                        ),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open PDF'),
              ),
              const SizedBox(width: 12),
              if ((_activePdf?.s3Url == null || _activePdf!.s3Url!.isEmpty) &&
                  (_activePdf?.path == null || _activePdf!.path.isEmpty))
                Text(
                  'No viewable URL yet. It may still be processing.',
                  style: TextStyle(color: Colors.grey.shade600),
                ),
            ],
          ),
        ],
      );
    }

    return Card(
      elevation: 0,
      color: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty) ...[
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: Colors.grey.shade700),
                  const SizedBox(width: 8),
                ],
                Expanded(child: contentWidget),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputSection(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: const Color.fromARGB(255, 4, 67, 153),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _isLoading ? null : _pickFile,
                  color: Colors.white,
                ),
                IconButton(
                  icon: const Icon(Icons.camera_alt),
                  onPressed: _isLoading ? null : _openCameraAndCreatePdf,
                  color: Colors.white,
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    enabled: !_isLoading,
                    decoration: InputDecoration(
                      hintText: 'Enter your query',
                      border: InputBorder.none,
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  color: Colors.white,
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _isLoading ? null : _sendMessage,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PopupMenuButton<String>(
                  onSelected: (val) => setState(() => _selectedLlm = val),
                  enabled: !_isLoading,
                  itemBuilder: (context) => _llmOptions
                      .map(
                        (choice) => PopupMenuItem<String>(
                          value: choice,
                          child: Text(choice),
                        ),
                      )
                      .toList(),
                  child: Chip(
                    avatar: _selectedLlm == null
                        ? const Icon(Icons.add, size: 18)
                        : null,
                    label: Text(_selectedLlm ?? 'LLM'),
                    backgroundColor: _selectedLlm != null
                        ? Colors.green.shade100
                        : const Color.fromARGB(255, 255, 189, 89),
                    labelStyle: TextStyle(
                      color: _selectedLlm != null
                          ? Colors.green.shade900
                          : const Color.fromARGB(255, 4, 67, 153),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: _selectedLlm != null
                            ? Colors.green.shade200
                            : const Color.fromARGB(255, 255, 189, 89),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat'),
        backgroundColor: const Color.fromARGB(255, 4, 67, 153),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _goHome,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16.0),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageCard(
                  title: message.title ?? '',
                  content: message.content,
                  type: message.type,
                );
              },
            ),
          ),
          if (_isLoading) const LinearProgressIndicator(),
          _buildInputSection(context),
        ],
      ),
    );
  }
}

// lib/views/home/home_screen.dart
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/chat_history_provider.dart';
import '../../providers/pdf_provider.dart';
import "../pdf/pdf_viewer_screen.dart";
import '../camera/camera_screen.dart';
import '../chat/chat_screen.dart';
import 'package:path/path.dart' as p;

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const HomeScreen({super.key, required this.cameras});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  void _fetchInitialData() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      const userEmail = "test@example.com";
      Provider.of<ChatHistoryProvider>(
        context,
        listen: false,
      ).fetchHistory(userEmail);
      Provider.of<PdfProvider>(
        context,
        listen: false,
      ).fetchRecentPdfs(userEmail);
    });
  }

  void _navigateToChatAndRefresh(Widget chatScreen) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => chatScreen),
    ).then((_) {
      if (!mounted) return;
      const userEmail = "test@example.com";
      Provider.of<ChatHistoryProvider>(
        context,
        listen: false,
      ).fetchHistory(userEmail);
      Provider.of<PdfProvider>(
        context,
        listen: false,
      ).fetchRecentPdfs(userEmail);
    });
  }

  Future<void> _onCameraPressed() async {
    if (widget.cameras.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No cameras found!')));
      return;
    }

    final result = await Navigator.push<Map<String, String>?>(
      context,
      MaterialPageRoute(
        builder: (context) => CameraScreen(cameras: widget.cameras),
      ),
    );

    if (result == null) return;
    final localPath = result['localPath'];
    final fileName =
        result['name'] ?? (localPath != null ? p.basename(localPath) : null);
    if (localPath == null || fileName == null) return;

    // Let ChatScreen handle upload & chat creation
    // change to push so user can go back to Home
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          pdfFile: PdfFile(id: '', path: localPath, name: fileName),
          cameras: widget.cameras,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    String id, {
    bool isPdf = false,
  }) async {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(isPdf ? 'Delete PDF' : 'Delete Chat'),
          content: Text(
            isPdf
                ? 'Are you sure you want to permanently delete this PDF and its associated data?'
                : 'Are you sure you want to delete this chat history?',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              child: const Text('Delete'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                if (isPdf) {
                  Provider.of<PdfProvider>(
                    context,
                    listen: false,
                  ).deletePdf(id);
                } else {
                  Provider.of<ChatHistoryProvider>(
                    context,
                    listen: false,
                  ).deleteConversation(id);
                }
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<PdfProvider, ChatHistoryProvider>(
      builder: (context, pdfProvider, historyProvider, child) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('ServiScribe'),
            elevation: 1,
            backgroundColor: const Color.fromARGB(255, 4, 67, 153),
            foregroundColor: Colors.white,
            actions: [
              IconButton(
                icon: const Icon(Icons.camera_alt_outlined),
                onPressed: _onCameraPressed,
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ElevatedButton(
                  onPressed: () => _navigateToChatAndRefresh(
                    ChatScreen(cameras: widget.cameras),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade50,
                    foregroundColor: Colors.blue.shade800,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.add_comment_outlined),
                      SizedBox(width: 12),
                      Text('New chat', style: TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Recent PDFs',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                if (pdfProvider.isLoading)
                  const Center(child: CircularProgressIndicator())
                else if (pdfProvider.recentPdfs.isEmpty)
                  const Text('No recent PDFs. Scan one to get started!')
                else
                  ...pdfProvider.recentPdfs.map((pdf) {
                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: Colors.grey.shade300),
                      ),
                      margin: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        leading: const Icon(
                          Icons.picture_as_pdf_outlined,
                          color: Colors.grey,
                        ),
                        title: Text(pdf.name, overflow: TextOverflow.ellipsis),
                        onTap: () {
                          // Open ChatScreen for an existing server-side document (don't re-upload)
                          Navigator.of(context)
                              .push(
                                MaterialPageRoute(
                                  builder: (_) => ChatScreen(
                                    s3Key: pdf.s3Key,
                                    fileId: pdf.id,
                                    fileName: pdf.name,
                                    cameras: widget.cameras,
                                  ),
                                ),
                              )
                              .then((_) {
                                // refresh lists after returning
                                const userEmail = "test@example.com";
                                Provider.of<ChatHistoryProvider>(
                                  context,
                                  listen: false,
                                ).fetchHistory(userEmail);
                                Provider.of<PdfProvider>(
                                  context,
                                  listen: false,
                                ).fetchRecentPdfs(userEmail);
                              });
                        },
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // view button (unchanged)
                            IconButton(
                              icon: const Icon(
                                Icons.visibility_outlined,
                                color: Colors.blueGrey,
                              ),
                              onPressed: () {
                                if (pdf.s3Url != null &&
                                    pdf.s3Url!.isNotEmpty) {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => PdfViewerScreen(
                                        title: pdf.name,
                                        url: pdf.s3Url!,
                                      ),
                                    ),
                                  );
                                } else if (pdf.path.isNotEmpty) {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => PdfViewerScreen(
                                        title: pdf.name,
                                        localPath: pdf.path,
                                      ),
                                    ),
                                  );
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'File not available locally or remotely',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
                              onPressed: () =>
                                  _confirmDelete(context, pdf.id, isPdf: true),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                const SizedBox(height: 24),
                const Text(
                  'History',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                if (historyProvider.isLoading)
                  const Center(child: CircularProgressIndicator())
                else if (historyProvider.conversations.isEmpty)
                  const Text('No chat history found.')
                else
                  Expanded(
                    child: ListView(
                      children: historyProvider.conversations.map((convo) {
                        return Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(color: Colors.grey.shade300),
                          ),
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            leading: const Icon(
                              Icons.chat_bubble_outline,
                              color: Colors.grey,
                            ),
                            title: Text(
                              convo.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _navigateToChatAndRefresh(
                              ChatScreen(
                                conversation: convo,
                                cameras: widget.cameras,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
                              onPressed: () =>
                                  _confirmDelete(context, convo.id),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

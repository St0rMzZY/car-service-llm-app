// lib/providers/chat_history_provider.dart
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';
import '../models/chat_message.dart';

/// Conversation model used by UI. Includes optional s3 metadata so ChatScreen
/// can open the associated PDF easily.
class ChatConversation {
  final String id;
  final String title;
  final List<ChatMessage> messages;
  final String? s3Key;
  final String? s3Url;

  ChatConversation({
    required this.id,
    required this.title,
    required this.messages,
    this.s3Key,
    this.s3Url,
  });

  ChatConversation copyWith({
    String? id,
    String? title,
    List<ChatMessage>? messages,
    String? s3Key,
    String? s3Url,
  }) {
    return ChatConversation(
      id: id ?? this.id,
      title: title ?? this.title,
      messages: messages ?? this.messages,
      s3Key: s3Key ?? this.s3Key,
      s3Url: s3Url ?? this.s3Url,
    );
  }
}

class ChatHistoryProvider with ChangeNotifier {
  final List<ChatConversation> _conversations = [];
  bool _isLoading = false;

  UnmodifiableListView<ChatConversation> get conversations =>
      UnmodifiableListView(_conversations);
  bool get isLoading => _isLoading;

  /// Fetch conversation history for a user from backend /get-chat-history/{user_email}
  Future<void> fetchHistory(String userEmail) async {
    _isLoading = true;
    notifyListeners();
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/get-chat-history/$userEmail');
      final resp = await http.get(uri);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final body = jsonDecode(resp.body);
        final raw = body is Map && body.containsKey('history')
            ? body['history']
            : (body is List ? body : []);
        _conversations.clear();
        for (final c in (raw as List)) {
          final map = Map<String, dynamic>.from(c as Map);
          final cid =
              (map['id'] ?? map['_id'] ?? map['conversation_id'] ?? '').toString();
          final title = (map['title'] ??
                  map['name'] ??
                  map['conversation_title'] ??
                  '')
              .toString();

          final rawMessages = (map['messages'] as List<dynamic>?) ?? [];
          final msgs = rawMessages.map((m) {
            final mm = Map<String, dynamic>.from(m as Map);
            final q = (mm['query'] ?? mm['question'] ?? '').toString();
            final a = (mm['answer'] ?? mm['response'] ?? '').toString();
            return ChatMessage(
              type: MessageType.reply,
              title: q.isNotEmpty ? 'Q: $q' : 'Reply',
              content: a,
            );
          }).toList();

          String? s3Key = (map['s3_key'] ?? map['s3Key'] ?? '').toString();
          if (s3Key.isEmpty) s3Key = null;
          String? s3Url = (map['s3_url'] ?? map['s3Url'] ?? map['s3_uri'] ?? '').toString();
          if (s3Url.isEmpty) s3Url = null;

          if (s3Key == null || s3Url == null) {
            for (final m in rawMessages) {
              final mm = Map<String, dynamic>.from(m as Map);
              final k = (mm['s3_key'] ?? mm['s3Key'] ?? '').toString();
              final u = (mm['s3_url'] ?? mm['s3Url'] ?? mm['s3_uri'] ?? '').toString();
              if ((s3Key == null || s3Key.isEmpty) && k.isNotEmpty) s3Key = k;
              if ((s3Url == null || s3Url.isEmpty) && u.isNotEmpty) s3Url = u;
            }
          }

          final conv = ChatConversation(
            id: cid.isNotEmpty ? cid : DateTime.now().millisecondsSinceEpoch.toString(),
            title: title.isNotEmpty ? title : 'Conversation',
            messages: msgs,
            s3Key: s3Key,
            s3Url: s3Url,
          );

          _conversations.add(conv);
        }
      } else {
        _conversations.clear();
        if (kDebugMode) {
          print('fetchHistory server returned ${resp.statusCode}: ${resp.body}');
        }
      }
    } catch (e) {
      if (kDebugMode) print('fetchHistory error: $e');
      _conversations.clear();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Create a chat row on server referencing a PDF. Returns ChatConversation if created.
  Future<ChatConversation?> createChatWithPdf({
    required String title,
    required String pdfId,
    String? pdfS3Url,
    String? pdfS3Key,
    required String initiatedByEmail,
  }) async {
    try {
      final resp = await ApiService.createChatFromS3(
        userEmail: initiatedByEmail,
        s3Key: pdfS3Key,
        s3Url: pdfS3Url,
        title: title,
        pdfId: pdfId,
      );

      final convId =
          (resp['conversation_id'] ?? resp['conversationId'] ?? '').toString();
      final message = (resp['message'] ?? '').toString();
      final serverMsgs = (resp['messages'] as List<dynamic>?) ?? [];

      final s3urlFromResp = (resp['s3_url'] ?? resp['s3Url'])?.toString();

      final msgs = <ChatMessage>[];
      if (message.isNotEmpty) {
        msgs.add(ChatMessage(type: MessageType.reply, title: 'Note', content: message));
      }
      for (final m in serverMsgs) {
        final map = Map<String, dynamic>.from(m as Map);
        final ans = (map['answer'] ?? map['answerText'] ?? '').toString();
        msgs.add(ChatMessage(type: MessageType.reply, title: 'Reply', content: ans));
      }

      final conv = ChatConversation(
        id: convId.isNotEmpty ? convId : DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        messages: msgs,
        s3Key: pdfS3Key,
        s3Url: s3urlFromResp ?? pdfS3Url,
      );

      _conversations.insert(0, conv);
      notifyListeners();
      return conv;
    } catch (e) {
      if (kDebugMode) print('createChatWithPdf primary failed: $e');
      try {
        final payload = {
          'title': title,
          'pdf_id': pdfId,
          'pdf_s3_url': pdfS3Url,
          if (pdfS3Key != null) 's3_key': pdfS3Key,
          'user_email': initiatedByEmail,
        };
        final resp = await ApiService.createChat(payload);
        final convId = (resp['conversation_id'] ?? resp['conversationId'] ?? '').toString();
        final serverMsgs = (resp['messages'] as List<dynamic>?) ?? [];
        final msgs = <ChatMessage>[];
        for (final m in serverMsgs) {
          final map = Map<String, dynamic>.from(m as Map);
          final ans = (map['answer'] ?? '').toString();
          msgs.add(ChatMessage(type: MessageType.reply, title: 'Reply', content: ans));
        }
        final s3urlFromResp = (resp['s3_url'] ?? resp['s3Url'])?.toString();
        final conv = ChatConversation(
          id: convId.isNotEmpty ? convId : DateTime.now().millisecondsSinceEpoch.toString(),
          title: title,
          messages: msgs,
          s3Key: pdfS3Key,
          s3Url: s3urlFromResp ?? pdfS3Url,
        );
        _conversations.insert(0, conv);
        notifyListeners();
        return conv;
      } catch (err) {
        if (kDebugMode) print('createChatWithPdf fallback failed: $err');
        return null;
      }
    }
  }

  Future<void> deleteConversation(String conversationId) async {
    try {
      final uri = Uri.parse('${ApiService.baseUrl}/delete-chat/$conversationId');
      final resp = await http.delete(uri);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        _conversations.removeWhere((c) => c.id == conversationId);
        notifyListeners();
      } else {
        if (kDebugMode) print('deleteConversation server returned ${resp.statusCode}: ${resp.body}');
      }
    } catch (e) {
      if (kDebugMode) print('deleteConversation error: $e');
    }
  }
}

// lib/services/api_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'https://api.intisca.com';

  static dynamic _decodeBody(http.Response resp) {
    final jsonBody = jsonDecode(resp.body);
    if (jsonBody is Map && jsonBody.containsKey('files')) {
      return jsonBody['files'];
    }
    return jsonBody;
  }

  static Future<Map<String, dynamic>> processDocument(
    String localPath,
    String userEmail,
  ) async {
    final uri = Uri.parse('$baseUrl/process-document?user_email=$userEmail');
    final request = http.MultipartRequest('POST', uri);
    request.files.add(await http.MultipartFile.fromPath('file', localPath));
    final streamed = await request.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final Map<String, dynamic> data = jsonDecode(resp.body);
      // Normalize keys
      return {
        's3_url': data['s3_url'] ?? data['s3Url'],
        's3_key': data['s3_key'] ?? data['s3Key'],
        'file_id': data['file_id'] ?? data['fileId'],
        'file_name': data['file_name'] ?? data['fileName'],
        'conversation_id': data['conversation_id'] ?? data['conversationId'],
        'messages': data['messages'] ?? data['Messages'] ?? [],
        ...data,
      };
    } else {
      throw Exception('Error from API (${resp.statusCode}): ${resp.body}');
    }
  }

  static Future<List<dynamic>> listFiles(String userEmail) async {
    final uri = Uri.parse('$baseUrl/list-files/$userEmail');
    final resp = await http.get(uri);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final decoded = _decodeBody(resp);
      if (decoded is List) {
        return decoded.map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          m['s3_url'] = m['s3_url'] ?? m['s3Url'] ?? m['s3_uri'] ?? m['s3Uri'];
          m['s3_key'] = m['s3_key'] ?? m['s3Key'] ?? m['s3_key'];
          m['file_id'] = m['id'] ?? m['file_id'] ?? m['fileId'];
          m['file_name'] =
              m['file_name'] ??
              m['fileName'] ??
              m['file_name'] ??
              m['file_name'];
          return m;
        }).toList();
      } else {
        return [];
      }
    } else {
      throw Exception('Error listing files: ${resp.statusCode}');
    }
  }

  static Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> payload,
  ) async {
    final uri = Uri.parse('$baseUrl/create-chat');
    final resp = await http.post(
      uri,
      body: jsonEncode(payload),
      headers: {'Content-Type': 'application/json'},
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } else if (resp.statusCode == 425) {
      throw Exception('425: Document not ready');
    } else {
      throw Exception('Error creating chat: ${resp.statusCode} ${resp.body}');
    }
  }

  static Future<Map<String, dynamic>> createChatFromS3({
    required String userEmail,
    String? s3Key,
    String? s3Url,
    String? title,
    String? pdfId,
    String? conversationId,
  }) async {
    final uri = Uri.parse('$baseUrl/create-chat-from-s3');
    final body = {
      'user_email': userEmail,
      if (s3Key != null) 's3_key': s3Key,
      if (s3Url != null) 's3_url': s3Url,
      if (title != null) 'title': title,
      if (pdfId != null) 'pdf_id': pdfId,
      if (conversationId != null) 'conversation_id': conversationId,
    };
    final resp = await http.post(
      uri,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

    if (resp.statusCode == 200 || resp.statusCode == 202) {
      if (resp.body.isNotEmpty) {
        try {
          return jsonDecode(resp.body) as Map<String, dynamic>;
        } catch (_) {
          return {};
        }
      }
      return {};
    } else if (resp.statusCode == 425) {
      throw Exception('425: Document not ready');
    } else {
      throw Exception(
        'Error createChatFromS3: ${resp.statusCode} ${resp.body}',
      );
    }
  }

  static Future<Map<String, dynamic>> getChatReply({
    required String query,
    required String? userEmail,
    required String? s3Url,
    required String? s3Key,
    required String? llm,
    String? conversationId,
  }) async {
    final uri = Uri.parse('$baseUrl/answer-query');
    try {
      final body = <String, dynamic>{
        'query': query,
        'user_email': userEmail,
        'llm': llm?.toLowerCase(),
        's3_url': s3Url,
        'conversation_id': conversationId,
      };
      if (s3Key != null && s3Key.isNotEmpty) body['s3_key'] = s3Key;

      final res = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (res.statusCode == 200) {
        return jsonDecode(res.body) as Map<String, dynamic>;
      }

      if (res.statusCode == 425) {
        throw Exception(
          'Document still processing (425). Please try again shortly.',
        );
      }

      throw Exception('Error from API (${res.statusCode}): ${res.body}');
    } catch (e) {
      throw Exception('Could not connect to the server: $e');
    }
  }

  static Future<Map<String, dynamic>> fileStatus(String fileId) async {
    final uri = Uri.parse('$baseUrl/file-status/$fileId');
    final resp = await http.get(uri);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } else {
      throw Exception('Error fileStatus ${resp.statusCode}');
    }
  }

  static Future<void> deletePdf(String fileId) async {
    final uri = Uri.parse('$baseUrl/delete-file/$fileId');
    final resp = await http.delete(uri);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Delete failed: ${resp.statusCode}');
    }
  }
}

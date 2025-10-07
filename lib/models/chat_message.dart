enum MessageType { query, reply, fileInfo }

class ChatMessage {
  final String content;
  final MessageType type;
  final String? title;

  ChatMessage({
    required this.content,
    required this.type,
    this.title,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      content: json['content'] ?? '',
      type: MessageType.values.firstWhere(
        (e) => e.toString() == json['type'],
        orElse: () => MessageType.reply,
      ),
      title: json['title'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'content': content,
      'type': type.toString(),
      'title': title,
    };
  }
}

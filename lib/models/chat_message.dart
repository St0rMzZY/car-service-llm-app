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

  // Factory constructor to create a ChatMessage from a JSON map
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      content: json['content'] ?? '',
      // Convert the string from JSON back to an enum
      type: MessageType.values.firstWhere(
        (e) => e.toString() == json['type'],
        orElse: () => MessageType.reply,
      ),
      title: json['title'],
    );
  }

  // Method to convert a ChatMessage object to a JSON map
  Map<String, dynamic> toJson() {
    return {
      'content': content,
      // Convert the enum to a string for JSON serialization
      'type': type.toString(),
      'title': title,
    };
  }
}

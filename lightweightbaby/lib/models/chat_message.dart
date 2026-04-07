import 'dart:io';

enum MessageRole { user, assistant }

class ChatMessage {
  final String id;
  final MessageRole role;
  final String text;
  final String? imagePath;
  final bool isStreaming;
  final double? responseSeconds;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.imagePath,
    this.isStreaming = false,
    this.responseSeconds,
  });

  bool get hasImage => imagePath != null && File(imagePath!).existsSync();

  ChatMessage copyWith({
    String? text,
    String? imagePath,
    bool? isStreaming,
    double? responseSeconds,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      imagePath: imagePath ?? this.imagePath,
      isStreaming: isStreaming ?? this.isStreaming,
      responseSeconds: responseSeconds ?? this.responseSeconds,
    );
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();
}

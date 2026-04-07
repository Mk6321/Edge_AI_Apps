import 'dart:io';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';

class MessageCard extends StatelessWidget {
  final ChatMessage message;

  const MessageCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == MessageRole.user;
    final isDark = theme.brightness == Brightness.dark;
    final alignment =
        isUser ? MainAxisAlignment.end : MainAxisAlignment.start;
    final background = isUser
        ? (isDark ? const Color(0xFF16314E) : const Color(0xFFDDEBFF))
        : (isDark ? const Color(0xFF182230) : Colors.white);
    final borderColor = isUser
        ? (isDark ? const Color(0xFF244B77) : const Color(0xFFB9D4FF))
        : (isDark ? const Color(0xFF263548) : const Color(0xFFD7E0EE));
    final titleColor = isUser
        ? (isDark ? const Color(0xFFB7DBFF) : const Color(0xFF0C3C78))
        : (isDark ? const Color(0xFFC9D7E8) : const Color(0xFF37506B));
    final textColor =
        isDark ? const Color(0xFFF1F6FF) : const Color(0xFF132238);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: alignment,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: borderColor),
              ),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isUser ? 'You' : 'LFM2-VL',
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (message.hasImage) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(message.imagePath!),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 120,
                            width: double.infinity,
                            color: isDark
                                ? const Color(0xFF202D3C)
                                : const Color(0xFFE9EEF6),
                            alignment: Alignment.center,
                            child: Text(
                              'Image preview unavailable',
                              style: TextStyle(color: textColor),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  if (message.text.trim().isNotEmpty || message.isStreaming) ...[
                    const SizedBox(height: 10),
                    SelectableText(
                      message.text.trim().isEmpty
                          ? 'Generating response...'
                          : message.text,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 15,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (!isUser &&
                      !message.isStreaming &&
                      message.responseSeconds != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Text(
                        '${message.responseSeconds!.toStringAsFixed(1)} s',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF8EA4BD)
                              : const Color(0xFF6B7F98),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

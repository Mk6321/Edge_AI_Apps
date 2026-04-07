import 'package:flutter/material.dart';

class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool hasImage;
  final VoidCallback onSend;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.hasImage,
    required this.onSend,
    required this.onPickImage,
    required this.onClearImage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final borderColor = theme.colorScheme.outlineVariant;
    final containerColor =
        isDark ? const Color(0xFF0F1722) : const Color(0xFFF8FAFD);
    final chipColor =
        isDark ? const Color(0xFF182D45) : const Color(0xFFE7F0FD);
    final chipBorder =
        isDark ? const Color(0xFF294766) : const Color(0xFFC3D9FA);
    final chipText =
        isDark ? const Color(0xFFBEDCFF) : const Color(0xFF0F3F78);

    return Container(
      decoration: BoxDecoration(
        color: containerColor,
        border: Border(
          top: BorderSide(color: borderColor),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasImage)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: chipColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: chipBorder),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.image_outlined,
                        size: 18,
                        color: chipText,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Image attached',
                          style: TextStyle(
                            color: chipText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: enabled ? onClearImage : null,
                        icon: const Icon(Icons.close),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Remove image',
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: enabled ? onPickImage : null,
                    icon: const Icon(Icons.add_a_photo_outlined),
                    tooltip: 'Attach image',
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, child) {
                        return TextField(
                          controller: controller,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) {
                            if (enabled &&
                                (value.text.trim().isNotEmpty || hasImage)) {
                              onSend();
                            }
                          },
                          decoration: InputDecoration(
                            hintText: hasImage
                                ? 'Add a question for the image'
                                : 'Type a message',
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, child) {
                      final canSend =
                          enabled && (value.text.trim().isNotEmpty || hasImage);

                      return FilledButton(
                        onPressed: canSend ? onSend : null,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(54, 54),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Icon(Icons.send_rounded),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

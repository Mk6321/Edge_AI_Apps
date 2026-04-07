import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/chat_message.dart';
import '../services/lfm_service.dart';
import '../services/model_manager.dart';
import '../widgets/chat_composer.dart';
import '../widgets/message_card.dart';

class HomeScreen extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  const HomeScreen({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ModelManager _modelManager = ModelManager();
  final LfmService _lfmService = LfmService();
  final ImagePicker _imagePicker = ImagePicker();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _promptController = TextEditingController();

  List<ChatMessage> _messages = <ChatMessage>[];
  bool _checkingFiles = true;
  bool _filesReady = false;
  bool _downloadingFiles = false;
  bool _loadingRuntime = false;
  bool _sending = false;
  String _statusText = 'Checking local files...';
  String? _errorMessage;
  String? _selectedImagePath;
  double _downloadProgress = 0;
  int _downloadedBytes = 0;
  int _totalDownloadBytes = ModelManager.estimatedTotalBytes;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _promptController.dispose();
    unawaited(_lfmService.dispose());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _checkingFiles = true;
      _errorMessage = null;
      _statusText = 'Checking local files...';
    });

    try {
      final filesReady = await _modelManager.areAssetsReady();
      if (!mounted) {
        return;
      }

      setState(() {
        _checkingFiles = false;
        _filesReady = filesReady;
        _statusText = filesReady
            ? 'Model files are ready.'
            : 'Model download required.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _checkingFiles = false;
        _errorMessage = error.toString();
        _statusText = 'Unable to check files.';
      });
    }
  }

  Future<void> _downloadFiles() async {
    setState(() {
      _downloadingFiles = true;
      _errorMessage = null;
      _downloadProgress = 0;
      _downloadedBytes = 0;
      _totalDownloadBytes = ModelManager.estimatedTotalBytes;
      _statusText = 'Starting download...';
    });

    try {
      await _modelManager.downloadRequiredFiles(
        onProgress: (progress) {
          if (!mounted) {
            return;
          }

          setState(() {
            _statusText = '${progress.title}: ${progress.filename}';
            _downloadProgress = progress.overallProgress;
            _downloadedBytes = progress.receivedBytes;
            _totalDownloadBytes = progress.totalBytes;
          });
        },
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _downloadingFiles = false;
        _filesReady = true;
        _statusText = 'Files ready. Load the model.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _downloadingFiles = false;
        _errorMessage = error.toString();
        _statusText = 'Download failed.';
      });
    }
  }

  Future<void> _loadRuntime() async {
    setState(() {
      _loadingRuntime = true;
      _errorMessage = null;
      _statusText = 'Loading model...';
    });

    try {
      await _lfmService.load(
        modelPath: await _modelManager.modelPath,
        projectorPath: await _modelManager.projectorPath,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _loadingRuntime = false;
        _statusText = 'Ready';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loadingRuntime = false;
        _errorMessage = error.toString();
        _statusText = 'Model load failed.';
      });
    }
  }

  Future<void> _sendPrompt() async {
    if (!_lfmService.isReady || _sending) {
      return;
    }

    final rawPrompt = _promptController.text.trim();
    final imagePath = _selectedImagePath;
    if (rawPrompt.isEmpty && imagePath == null) {
      return;
    }

    final prompt =
        rawPrompt.isEmpty ? 'Describe this image briefly.' : rawPrompt;
    final priorMessages = List<ChatMessage>.from(_messages);
    final userMessage = ChatMessage(
      id: ChatMessage.newId(),
      role: MessageRole.user,
      text: prompt,
      imagePath: imagePath,
    );
    final assistantMessage = ChatMessage(
      id: ChatMessage.newId(),
      role: MessageRole.assistant,
      text: '',
      isStreaming: true,
    );

    _promptController.clear();
    setState(() {
      _messages = <ChatMessage>[
        ..._messages,
        userMessage,
        assistantMessage,
      ];
      _selectedImagePath = null;
      _sending = true;
      _errorMessage = null;
    });
    _scrollToBottom();

    final stopwatch = Stopwatch()..start();
    final buffer = StringBuffer();

    try {
      await for (final chunk in _lfmService.reply(
        history: priorMessages,
        prompt: prompt,
        imagePath: imagePath,
      )) {
        buffer.write(chunk);

        if (!mounted) {
          return;
        }

        setState(() {
          _updateLatestAssistantMessage(
            text: buffer.toString(),
            isStreaming: true,
          );
        });
        _scrollToBottom();
      }

      stopwatch.stop();
      if (!mounted) {
        return;
      }

      setState(() {
        _sending = false;
        _updateLatestAssistantMessage(
          text: buffer.toString().trim().isEmpty
              ? 'No response was generated.'
              : buffer.toString(),
          isStreaming: false,
          responseSeconds: stopwatch.elapsedMilliseconds / 1000,
        );
      });
    } catch (error) {
      stopwatch.stop();
      if (!mounted) {
        return;
      }

      setState(() {
        _sending = false;
        _updateLatestAssistantMessage(
          text: 'Error: $error',
          isStreaming: false,
          responseSeconds: stopwatch.elapsedMilliseconds / 1000,
        );
      });
    }
  }

  void _updateLatestAssistantMessage({
    required String text,
    required bool isStreaming,
    double? responseSeconds,
  }) {
    if (_messages.isEmpty) {
      return;
    }

    final lastIndex = _messages.length - 1;
    final lastMessage = _messages[lastIndex];
    if (lastMessage.role != MessageRole.assistant) {
      return;
    }

    _messages[lastIndex] = lastMessage.copyWith(
      text: text,
      isStreaming: isStreaming,
      responseSeconds: responseSeconds,
    );
  }

  Future<void> _pickImage() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('Take photo'),
                onTap: () {
                  Navigator.of(context).pop();
                  _selectImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.of(context).pop();
                  _selectImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _selectImage(ImageSource source) async {
    try {
      final file = await _imagePicker.pickImage(
        source: source,
        maxWidth: 768,
        maxHeight: 768,
        imageQuality: 72,
      );

      if (!mounted || file == null) {
        return;
      }

      setState(() {
        _selectedImagePath = file.path;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _errorMessage = 'Image selection failed: $error';
      });
    }
  }

  void _clearConversation() {
    setState(() {
      _messages = <ChatMessage>[];
      _selectedImagePath = null;
    });
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lightweight Baby'),
        actions: [
          IconButton(
            onPressed: widget.onToggleTheme,
            tooltip: widget.isDarkMode ? 'Light mode' : 'Dark mode',
            icon: Icon(
              widget.isDarkMode
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
          ),
          if (_lfmService.isReady)
            IconButton(
              onPressed: _messages.isEmpty ? null : _clearConversation,
              tooltip: 'Clear conversation',
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _lfmService.isReady ? _buildChatLayout() : _buildSetupLayout(),
    );
  }

  Widget _buildSetupLayout() {
    final theme = Theme.of(context);
    final busy = _checkingFiles || _downloadingFiles || _loadingRuntime;
    final canDownload = !busy && !_filesReady;
    final canLoad = !busy && _filesReady;
    final borderColor = theme.brightness == Brightness.dark
        ? const Color(0xFF263548)
        : const Color(0xFFD9E3F0);

    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: borderColor),
                ),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Offline setup',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Download the model once, then start chatting.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _statusText,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _buildProgressSubtitle(),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 18),
                    LinearProgressIndicator(
                      value: busy && _downloadProgress > 0
                          ? _downloadProgress
                          : busy
                              ? null
                              : _filesReady
                                  ? 1
                                  : 0,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: theme.brightness == Brightness.dark
                              ? const Color(0xFF3A1C22)
                              : const Color(0xFFFFF1EF),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: theme.brightness == Brightness.dark
                                ? const Color(0xFF72404A)
                                : const Color(0xFFFFD4CF),
                          ),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(color: Color(0xFFD96C5B)),
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: canDownload
                            ? _downloadFiles
                            : canLoad
                                ? _loadRuntime
                                : null,
                        child: Text(
                          canLoad ? 'Load model' : 'Download files',
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: busy ? null : _bootstrap,
                        child: const Text('Check again'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChatLayout() {
    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(top: 10, bottom: 12),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    return MessageCard(message: _messages[index]);
                  },
                ),
        ),
        ChatComposer(
          controller: _promptController,
          enabled: !_sending,
          hasImage: _selectedImagePath != null,
          onSend: _sendPrompt,
          onPickImage: _pickImage,
          onClearImage: () {
            setState(() {
              _selectedImagePath = null;
            });
          },
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    final circleColor = theme.brightness == Brightness.dark
        ? const Color(0xFF182D45)
        : const Color(0xFFE4F0FB);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: circleColor,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_awesome_outlined,
                size: 34,
                color: Color(0xFF0F6CBD),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Ask a question or attach an image.',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildProgressSubtitle() {
    if (_downloadingFiles) {
      return '${ModelManager.formatBytes(_downloadedBytes)} / '
          '${ModelManager.formatBytes(_totalDownloadBytes)}';
    }
    if (_filesReady) {
      return 'The model files are already on this device.';
    }
    return 'About 323 MB total download.';
  }
}

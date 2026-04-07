import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/chat_message.dart';
import '../services/esp32_service.dart';
import '../services/face_service.dart';
import '../services/intent_router.dart';
import '../services/lfm_service.dart';
import '../services/model_manager.dart';

// =============================================================================
// STATE MACHINE
//
//   settingUp → (download → load model) → idle
//   idle ──tap──► listening ──finalResult──►
//     ├── processing (vision/ocr/recognize) ──done──► idle
//     └── awaitingDescription ──mic──► processing (register) ──done──► idle
// =============================================================================
enum _AppState { settingUp, idle, listening, awaitingDescription, processing }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ── Services ───────────────────────────────────────────────────────────────
  final ModelManager _modelManager = ModelManager();
  final LfmService _lfmService = LfmService();
  final FaceService _faceService = FaceService();
  final Esp32Service _esp32 =
      Esp32Service(captureUrl: 'http://10.235.89.20/capture');
  late stt.SpeechToText _speech;
  late FlutterTts _flutterTts;

  // ── UI state ───────────────────────────────────────────────────────────────
  _AppState _appState = _AppState.settingUp;
  String _statusText  = 'Checking model files...';
  String _lastQuery   = '';
  String _response    = '';
  Uint8List? _capturedImage;

  // ── Model setup state ──────────────────────────────────────────────────────
  bool _filesReady      = false;
  bool _downloading     = false;
  bool _loadingModel    = false;
  double _downloadPct   = 0;
  String? _errorMessage;

  // ── Registration state ─────────────────────────────────────────────────────
  bool   _isWaitingForDescription = false;
  String _pendingName             = '';

  // ── Chat history (for LFM context) ─────────────────────────────────────────
  final List<ChatMessage> _chatHistory = [];

  // ---------------------------------------------------------------------------
  // LIFECYCLE
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _initVoice();
    _requestPermissions();
    _bootstrap();
  }

  @override
  void dispose() {
    _speech.cancel();
    _flutterTts.stop();
    unawaited(_lfmService.dispose());
    unawaited(_faceService.dispose());
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // SETUP
  // ---------------------------------------------------------------------------

  Future<void> _requestPermissions() async {
    await [Permission.microphone, Permission.camera, Permission.speech].request();
  }

  Future<void> _initVoice() async {
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setPitch(1.0);
  }

  // ---------------------------------------------------------------------------
  // MODEL BOOTSTRAP (download → load LFM + initialize FaceService)
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    setState(() {
      _appState = _AppState.settingUp;
      _errorMessage = null;
      _statusText = 'Checking model files...';
    });

    try {
      final ready = await _modelManager.areAssetsReady();
      if (!mounted) return;
      setState(() {
        _filesReady = ready;
        _statusText = ready ? 'Model files ready. Tap Load.' : 'Download required (~323 MB).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _statusText = 'Error checking files.';
      });
    }
  }

  Future<void> _downloadFiles() async {
    setState(() {
      _downloading = true;
      _errorMessage = null;
      _downloadPct = 0;
      _statusText = 'Starting download...';
    });

    try {
      await _modelManager.downloadRequiredFiles(
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _downloadPct = p.overallProgress;
            _statusText = '${p.title}: ${p.filename}';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _filesReady = true;
        _statusText = 'Download complete. Tap Load.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _errorMessage = e.toString();
        _statusText = 'Download failed.';
      });
    }
  }

  Future<void> _loadModel() async {
    setState(() {
      _loadingModel = true;
      _errorMessage = null;
      _statusText = 'Loading models...';
    });

    try {
      // Load LFM2-VL
      await _lfmService.load(
        modelPath: await _modelManager.modelPath,
        projectorPath: await _modelManager.projectorPath,
      );
      print('[BOOT] LFM2-VL loaded.');

      // Load FaceService (ML Kit + MobileFaceNet + vault)
      await _faceService.initialize();
      print('[BOOT] FaceService initialized.');

      if (!mounted) return;
      setState(() {
        _loadingModel = false;
        _appState = _AppState.idle;
        _statusText = 'Ready — tap the mic.';
      });
      _speak('All models loaded. Ready.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingModel = false;
        _errorMessage = e.toString();
        _statusText = 'Model load failed.';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // TTS HELPERS
  // ---------------------------------------------------------------------------

  Future<void> _speak(String text) async {
    print('[TTS] $text');
    await _flutterTts.speak(text);
  }

  Future<void> _speakAndWait(String text) async {
    print('[TTS] speakAndWait: $text');
    final c = Completer<void>();
    _flutterTts.setCompletionHandler(() {
      if (!c.isCompleted) c.complete();
    });
    await _flutterTts.speak(text);
    await c.future;
  }

  // ---------------------------------------------------------------------------
  // ESP32-CAM CAPTURE
  // ---------------------------------------------------------------------------

  /// Captures image, updates UI preview, AND returns file path for models.
  Future<String?> _captureImage() async {
    print('[CAMERA] Capturing...');
    final bytes = await _esp32.captureBytes();
    if (bytes != null) setState(() => _capturedImage = bytes);

    final path = await _esp32.captureToFile();
    if (path == null) {
      _speak('Could not reach the camera.');
    } else {
      print('[CAMERA] File: $path (${bytes?.length ?? 0} bytes)');
    }
    return path;
  }

  // ---------------------------------------------------------------------------
  // MAIN LISTEN BUTTON
  // ---------------------------------------------------------------------------

  Future<void> _startListening() async {
    if (_appState != _AppState.idle) return;

    if (!_speech.isAvailable) {
      final ok = await _speech.initialize(
        onError: (e) => print('[STT] error: ${e.errorMsg}'),
      );
      if (!ok) { _setStatus('Mic unavailable', _AppState.idle); return; }
    }

    setState(() {
      _lastQuery = '';
      _response = '';
      _isWaitingForDescription = false;
      _pendingName = '';
    });
    _setStatus('Listening...', _AppState.listening);

    await _speakAndWait("I'm listening.");

    _speech.listen(
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 4),
      listenOptions: stt.SpeechListenOptions(partialResults: true),
      onResult: (val) {
        if (val.recognizedWords.isNotEmpty && mounted) {
          setState(() => _lastQuery = val.recognizedWords);
        }
        if (val.finalResult) {
          print('[STT] Final: ${val.recognizedWords}');
          _onSpeechResult(val.recognizedWords);
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // ███████████████████████████████████████████████████████████████████████████
  // CENTRAL SPEECH RESULT HANDLER
  // ███████████████████████████████████████████████████████████████████████████

  Future<void> _onSpeechResult(String rawText) async {
    final text = rawText.toLowerCase().trim();
    if (text.isEmpty) return;

    print('[ROUTER] ═══════════════════════════════════════');
    print('[ROUTER] raw: "$rawText"');
    print('[ROUTER] isWaitingForDescription: $_isWaitingForDescription');
    print('[ROUTER] ═══════════════════════════════════════');

    // ══════════════════════════════════════════════════════════════════════════
    // BRANCH A: DESCRIPTION LOOP (highest priority — checked first)
    // ══════════════════════════════════════════════════════════════════════════
    if (_isWaitingForDescription) {
      print('[ROUTER] → DESCRIPTION LOOP');
      await _speech.stop();
      _isWaitingForDescription = false;

      String description = '';
      if (text.contains('no') && text.split(' ').length <= 3) {
        description = '';
        print('[REGISTER] User skipped description.');
      } else {
        description = rawText.trim();
        print('[REGISTER] Description: "$description"');
      }

      await _executeRegistration(_pendingName, description);
      return;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // BRANCH B: INTENT ROUTING (local keyword matching)
    // ══════════════════════════════════════════════════════════════════════════
    final routedPrompt = IntentRouter.getSystemPrompt(rawText);

    // ── Face Registration ────────────────────────────────────────────────────
    if (routedPrompt == IntentRouter.faceRegisterTrigger) {
      print('[ROUTER] → FACE REGISTER');
      final extractedName = IntentRouter.extractName(rawText);
      print('[REGISTER] Extracted name: "$extractedName"');

      setState(() {
        _pendingName = extractedName;
        _isWaitingForDescription = true;
      });

      await _speech.stop();
      _setStatus('Say description → $extractedName', _AppState.awaitingDescription);

      await _speakAndWait(
        'I heard $extractedName. '
        'Please say a description for this person, or say no.',
      );

      // Re-open mic for description
      if (!_speech.isAvailable) {
        await _speech.initialize(onError: (e) => print('[STT] Error: ${e.errorMsg}'));
      }
      _speech.listen(
        listenFor: const Duration(seconds: 15),
        pauseFor: const Duration(seconds: 4),
        listenOptions: stt.SpeechListenOptions(partialResults: true),
        onResult: (val) {
          if (val.recognizedWords.isNotEmpty && mounted) {
            setState(() => _lastQuery = val.recognizedWords);
          }
          if (val.finalResult) {
            print('[REGISTER] Description heard: "${val.recognizedWords}"');
            _onSpeechResult(val.recognizedWords);
          }
        },
      );
      return;
    }

    // ── Face Recognition ─────────────────────────────────────────────────────
    if (routedPrompt == IntentRouter.faceRecognizeTrigger) {
      print('[ROUTER] → FACE RECOGNIZE');
      await _speech.stop();
      await _handleFaceRecognition();
      return;
    }

    // ── OCR / General Vision (handled by lfm_service) ────────────────────────
    print('[ROUTER] → ${routedPrompt == IntentRouter.mlKitOcrTrigger ? "OCR" : "VISION"}');
    await _speech.stop();
    await _handleVisionOrOcr(rawText, routedPrompt);
  }

  // ---------------------------------------------------------------------------
  // FACE RECOGNITION FLOW
  // ---------------------------------------------------------------------------

  Future<void> _handleFaceRecognition() async {
    _setStatus('Capturing image...', _AppState.processing);
    await _speakAndWait('Let me check who is in front of you.');

    final imagePath = await _captureImage();
    if (imagePath == null) {
      _setStatus('Camera error', _AppState.idle);
      return;
    }

    // Stage 1: ML Kit face detection + crop
    _setStatus('Scanning for faces...', _AppState.processing);
    final cropPath = await _faceService.detectAndCropFace(imagePath);

    if (cropPath == null) {
      // No face found — skip Stage 2 entirely
      const msg = 'I do not see anyone in front of you.';
      setState(() => _response = msg);
      _setStatus('No face detected', _AppState.idle);
      _speak(msg);
      _cleanup([imagePath]);
      return;
    }

    // Stage 2: MobileFaceNet embedding + vault comparison
    _setStatus('Identifying...', _AppState.processing);
    try {
      final embedding = _faceService.getEmbedding(cropPath);
      final match = _faceService.recognizeFace(embedding);

      String msg;
      if (match != null) {
        final name = match['name']!;
        final desc = match['description'] ?? '';
        msg = desc.isNotEmpty
            ? 'This is $name. $desc.'
            : 'This is $name.';
      } else {
        msg = 'I see a person, but I do not recognize them.';
      }

      print('[RECOGNIZE] Result: $msg');
      setState(() => _response = msg);
      _setStatus('Done', _AppState.idle);
      _speak(msg);
    } catch (e) {
      print('[RECOGNIZE] Error: $e');
      setState(() => _response = 'Face recognition error.');
      _setStatus('Error', _AppState.idle);
      _speak('An error occurred during face recognition.');
    }

    _cleanup([imagePath, cropPath]);
  }

  // ---------------------------------------------------------------------------
  // FACE REGISTRATION EXECUTION
  // ---------------------------------------------------------------------------

  Future<void> _executeRegistration(String name, String description) async {
    print('[REGISTER] Executing — name="$name", desc="$description"');

    _setStatus('Capturing image...', _AppState.processing);
    await _speakAndWait('Registering. Please hold still.');

    final imagePath = await _captureImage();
    if (imagePath == null) {
      _setStatus('Camera error', _AppState.idle);
      _pendingName = '';
      return;
    }

    // Stage 1: detect face
    _setStatus('Detecting face...', _AppState.processing);
    final cropPath = await _faceService.detectAndCropFace(imagePath);

    if (cropPath == null) {
      const msg = 'I could not detect a face. Please try again.';
      setState(() => _response = msg);
      _setStatus('No face', _AppState.idle);
      _speak(msg);
      _pendingName = '';
      _cleanup([imagePath]);
      return;
    }

    // Stage 2: generate embedding + save to vault
    _setStatus('Saving $name...', _AppState.processing);
    try {
      final embedding = _faceService.getEmbedding(cropPath);
      await _faceService.registerFace(
        name: name,
        description: description,
        embedding: embedding,
        cropPath: cropPath,
      );

      final descMsg = description.isNotEmpty ? ' Description: $description.' : '';
      final msg = 'Successfully registered $name.$descMsg';
      print('[REGISTER] Done: $msg');
      setState(() { _response = msg; _pendingName = ''; });
      _setStatus('Registered: $name', _AppState.idle);
      _speak(msg);
    } catch (e) {
      print('[REGISTER] Error: $e');
      setState(() { _response = 'Registration failed.'; _pendingName = ''; });
      _setStatus('Error', _AppState.idle);
      _speak('Registration failed. Please try again.');
    }

    _cleanup([imagePath, cropPath]);
  }

  // ---------------------------------------------------------------------------
  // VISION / OCR FLOW (via LFM2-VL / ML Kit)
  // ---------------------------------------------------------------------------

  Future<void> _handleVisionOrOcr(String rawText, String routedPrompt) async {
    final isOcr = routedPrompt == IntentRouter.mlKitOcrTrigger;

    _setStatus('Capturing image...', _AppState.processing);
    if (isOcr) {
      await _speakAndWait('Reading the text.');
    } else {
      await _speakAndWait('Analyzing the scene.');
    }

    final imagePath = await _captureImage();
    if (imagePath == null) {
      _setStatus('Camera error', _AppState.idle);
      return;
    }

    _setStatus(isOcr ? 'Reading text...' : 'Analyzing scene...', _AppState.processing);

    final buffer = StringBuffer();
    try {
      await for (final chunk in _lfmService.reply(
        history: _chatHistory,
        prompt: rawText,
        imagePath: imagePath,
      )) {
        buffer.write(chunk);
        if (mounted) setState(() => _response = buffer.toString());
      }
    } catch (e) {
      print('[INFERENCE] Error: $e');
      buffer.write('Error: $e');
    }

    final result = buffer.toString().trim();
    final displayResult = result.isEmpty ? 'No response generated.' : result;

    _chatHistory.add(ChatMessage(id: ChatMessage.newId(), role: MessageRole.user, text: rawText, imagePath: imagePath));
    _chatHistory.add(ChatMessage(id: ChatMessage.newId(), role: MessageRole.assistant, text: displayResult));
    if (_chatHistory.length > 12) {
      _chatHistory.removeRange(0, _chatHistory.length - 12);
    }

    setState(() => _response = displayResult);
    _setStatus('Done', _AppState.idle);
    _speak(displayResult);

    _cleanup([imagePath]);
  }

  // ---------------------------------------------------------------------------
  // CANCEL + HELPERS
  // ---------------------------------------------------------------------------

  Future<void> _cancelListening() async {
    await _speech.stop();
    setState(() { _isWaitingForDescription = false; _pendingName = ''; });
    _setStatus('Cancelled', _AppState.idle);
    _speak('Stopped.');
  }

  void _setStatus(String text, _AppState state) {
    if (mounted) setState(() { _statusText = text; _appState = state; });
  }

  void _cleanup(List<String?> paths) {
    for (final p in paths) {
      if (p != null) {
        try { File(p).deleteSync(); } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_appState == _AppState.settingUp || !_lfmService.isReady) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(title: const Text('Smart Glass Edge AI')),
        body: _buildSetupUI(),
      );
    }

    final isActive = _appState == _AppState.listening ||
                     _appState == _AppState.awaitingDescription;
    final isProcessing = _appState == _AppState.processing;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(title: const Text('Smart Glass Edge AI')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusChip(),
            const SizedBox(height: 20),
            _buildImagePreview(),
            const SizedBox(height: 20),
            if (_lastQuery.isNotEmpty) ...[
              const Text('You said:', style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 4),
              Text('"$_lastQuery"',
                style: const TextStyle(color: Colors.white, fontSize: 18, fontStyle: FontStyle.italic)),
              const SizedBox(height: 16),
            ],
            if (_response.isNotEmpty) ...[
              const Text('AI Response:', style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 4),
              Text(_response,
                style: const TextStyle(color: Color(0xFF58A6FF), fontSize: 20, fontWeight: FontWeight.bold)),
            ],
            const SizedBox(height: 110),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: SizedBox(
          height: 110,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: isProcessing
                  ? Colors.orange.shade700
                  : isActive ? Colors.red.shade700 : const Color(0xFF238636),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            onPressed: isProcessing ? null : isActive ? _cancelListening : _startListening,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isProcessing ? Icons.hourglass_top : isActive ? Icons.mic_off : Icons.mic,
                  size: 36, color: Colors.white,
                ),
                const SizedBox(height: 8),
                Text(
                  isProcessing ? 'Processing...' : isActive ? 'Tap to Cancel' : 'Ask Question',
                  style: const TextStyle(fontSize: 26, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Setup UI ───────────────────────────────────────────────────────────────

  Widget _buildSetupUI() {
    final busy = _downloading || _loadingModel;
    final canDownload = !busy && !_filesReady;
    final canLoad = !busy && _filesReady;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.visibility, size: 64, color: Color(0xFF238636)),
            const SizedBox(height: 20),
            Text('Edge AI Setup',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text(_statusText, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 16)),
            const SizedBox(height: 20),
            if (busy)
              LinearProgressIndicator(
                value: _downloading && _downloadPct > 0 ? _downloadPct : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
              ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_errorMessage!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: canDownload ? _downloadFiles : canLoad ? _loadModel : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF238636),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  canLoad ? 'Load Model' : 'Download Files (~323 MB)',
                  style: const TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton(
                onPressed: busy ? null : _bootstrap,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF30363D)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Check Again', style: TextStyle(color: Colors.grey)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Sub-widgets ────────────────────────────────────────────────────────────

  Widget _buildStatusChip() {
    Color chipColor;
    switch (_appState) {
      case _AppState.settingUp:           chipColor = Colors.amber.shade700;  break;
      case _AppState.idle:                chipColor = Colors.green.shade700;  break;
      case _AppState.listening:           chipColor = Colors.blue.shade700;   break;
      case _AppState.awaitingDescription: chipColor = Colors.teal.shade700;   break;
      case _AppState.processing:          chipColor = Colors.purple.shade700; break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.2),
        border: Border.all(color: chipColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        if (_appState == _AppState.processing)
          const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
        else
          Icon(_stateIcon(), color: Colors.white, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(_statusText,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        ),
      ]),
    );
  }

  IconData _stateIcon() {
    switch (_appState) {
      case _AppState.settingUp:           return Icons.hourglass_top;
      case _AppState.idle:                return Icons.check_circle_outline;
      case _AppState.listening:           return Icons.mic;
      case _AppState.awaitingDescription: return Icons.record_voice_over;
      case _AppState.processing:          return Icons.hourglass_top;
    }
  }

  Widget _buildImagePreview() {
    if (_capturedImage != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          height: 280,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF30363D)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Image.memory(_capturedImage!, fit: BoxFit.cover),
        ),
      );
    }
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        border: Border.all(color: const Color(0xFF30363D)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.camera_alt_outlined, color: Colors.grey, size: 40),
          SizedBox(height: 8),
          Text('No image captured yet',
            style: TextStyle(color: Colors.grey, fontSize: 16)),
        ],
      ),
    );
  }
}

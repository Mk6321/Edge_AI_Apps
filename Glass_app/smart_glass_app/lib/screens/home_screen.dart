import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/api_service.dart';
import '../services/background_service.dart';
import '../services/face_service.dart';
import '../services/wake_word_config.dart';
import '../services/wake_word_constants.dart';

enum _AppState { idle, listening, awaitingDescription, processing }

enum _PreviewSource { none, esp32, phoneAttachment }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final ApiService _apiService = ApiService();
  final FaceService _faceService = FaceService();
  final ImagePicker _imagePicker = ImagePicker();
  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();

  late stt.SpeechToText _speech;
  late FlutterTts _flutterTts;

  StreamSubscription<Map<String, dynamic>?>? _wakeWordDetectedSubscription;
  StreamSubscription<Map<String, dynamic>?>? _wakeWordStatusSubscription;

  _AppState _appState = _AppState.idle;
  _PreviewSource _previewSource = _PreviewSource.none;

  String _statusText = 'Initializing...';
  String _lastQuery = '';
  String _serverResponse = '';
  String _pendingName = '';
  String _wakeWordMessage = WakeWordConfig.hasAccessKey
      ? 'Wake word service preparing...'
      : 'Wake word disabled until PICOVOICE_ACCESS_KEY is provided.';

  Uint8List? _capturedImage;
  String? _attachedImagePath;

  bool _isWaitingForDescription = false;
  bool _servicesReady = false;
  bool _wakeWordRunning = false;
  bool _wakeWordReady = WakeWordConfig.hasAccessKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindWakeWordStreams();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wakeWordDetectedSubscription?.cancel();
    _wakeWordStatusSubscription?.cancel();
    _speech.cancel();
    _flutterTts.stop();
    unawaited(_resumeWakeWordIfIdle());
    unawaited(_faceService.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_maybeHandlePendingWakeWord());
    }
  }

  bool get _hasAttachedImage => _attachedImagePath != null;

  Future<void> _bootstrap() async {
    await _initVoice();
    await _requestPermissions();
    await initializeService();
    await _restoreAttachedImage();
    await _recoverLostPhoneCapture();
    await _initServices();
  }

  void _bindWakeWordStreams() {
    _wakeWordDetectedSubscription = _backgroundService
        .on(wakeWordDetectedEvent)
        .listen((_) {
          unawaited(_maybeHandlePendingWakeWord());
        });

    _wakeWordStatusSubscription = _backgroundService
        .on(wakeWordStatusEvent)
        .listen((event) {
          if (!mounted || event == null) {
            return;
          }

          setState(() {
            _wakeWordReady = event['ready'] == true;
            _wakeWordRunning = event['running'] == true;
            final message = event['message'] as String?;
            if (message != null && message.isNotEmpty) {
              _wakeWordMessage = message;
            }
          });
        });
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.microphone,
      Permission.camera,
      Permission.speech,
      Permission.notification,
    ].request();
  }

  Future<void> _initVoice() async {
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _initServices() async {
    _setStatus('Initializing Gemini + Face Engine...', _AppState.idle);

    final bool pendingWakeWord = await _hasPendingWakeWord();

    try {
      await _apiService.init();
      await _faceService.initialize();

      _servicesReady = true;
      _setStatus('Ready - tap the mic.', _AppState.idle);

      if (!pendingWakeWord) {
        _speak('Ready.');
      }

      await _maybeHandlePendingWakeWord();
      await _resumeWakeWordIfIdle();
    } catch (error) {
      _setStatus('Init error: $error', _AppState.idle);
      _speak('Initialization failed.');
    }
  }

  void _setStatus(String text, _AppState state) {
    if (!mounted) {
      return;
    }

    setState(() {
      _statusText = text;
      _appState = state;
    });
  }

  Future<void> _pauseWakeWord() async {
    await pauseWakeWordDetection();
  }

  Future<void> _resumeWakeWordIfIdle() async {
    if (_appState == _AppState.idle) {
      await resumeWakeWordDetection();
    }
  }

  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  Future<void> _speakAndWait(String text) async {
    final completer = Completer<void>();
    _flutterTts.setCompletionHandler(() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    await _flutterTts.speak(text);
    await completer.future;
  }

  Future<bool> _hasPendingWakeWord() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(pendingWakeWordKey) ?? false;
  }

  Future<void> _clearPendingWakeWord() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(pendingWakeWordKey);
    await prefs.remove(pendingWakeWordAtKey);
  }

  Future<void> _maybeHandlePendingWakeWord() async {
    if (!_servicesReady || _appState != _AppState.idle) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getBool(pendingWakeWordKey) ?? false;
    if (!pending) {
      return;
    }

    await _clearPendingWakeWord();
    await _startListening(fromWakeWord: true);
  }

  Future<void> _startListening({bool fromWakeWord = false}) async {
    if (_appState != _AppState.idle) {
      return;
    }

    await _pauseWakeWord();
    await _clearPendingWakeWord();

    if (!_speech.isAvailable) {
      final ok = await _speech.initialize(
        onError: (error) => debugPrint('[STT] Init error: ${error.errorMsg}'),
      );
      if (!ok) {
        _setStatus('Mic unavailable', _AppState.idle);
        await _resumeWakeWordIfIdle();
        return;
      }
    }

    if (mounted) {
      setState(() {
        _lastQuery = '';
        _serverResponse = '';
        _isWaitingForDescription = false;
        _pendingName = '';
      });
    }

    _setStatus('Listening...', _AppState.listening);

    if (!fromWakeWord) {
      await _speakAndWait("I'm listening.");
    }

    _listenForSpeech();
  }

  void _listenForSpeech() {
    _speech.listen(
      listenFor: const Duration(seconds: 15),
      pauseFor: const Duration(seconds: 4),
      listenOptions: stt.SpeechListenOptions(partialResults: true),
      onResult: (result) {
        if (result.recognizedWords.isNotEmpty && mounted) {
          setState(() => _lastQuery = result.recognizedWords);
        }
        if (result.finalResult) {
          unawaited(_onSpeechResult(result.recognizedWords));
        }
      },
      onSoundLevelChange: (_) {},
    );
  }

  Future<void> _capturePhoneImage() async {
    if (_appState != _AppState.idle) {
      return;
    }

    await _pauseWakeWord();
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 90,
      );

      if (picked == null) {
        return;
      }

      await _attachPhoneImage(picked, announce: true);
      _setStatus('Phone image attached', _AppState.idle);
    } catch (error) {
      _setStatus('Phone camera error', _AppState.idle);
      await _speak('I could not capture a photo from the phone camera.');
      debugPrint('[PHONE-CAMERA] Error: $error');
    } finally {
      await _resumeWakeWordIfIdle();
    }
  }

  Future<void> _attachPhoneImage(XFile file, {required bool announce}) async {
    final bytes = await file.readAsBytes();
    final savedPath = await _persistAttachedImage(bytes);

    if (!mounted) {
      return;
    }

    setState(() {
      _attachedImagePath = savedPath;
      _capturedImage = bytes;
      _previewSource = _PreviewSource.phoneAttachment;
    });

    if (announce) {
      await _speak('Photo attached. Ask your question.');
    }
  }

  Future<String> _persistAttachedImage(Uint8List bytes) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final attachmentsDir = Directory('${docsDir.path}/attached_images');
    if (!await attachmentsDir.exists()) {
      await attachmentsDir.create(recursive: true);
    }

    final file = File('${attachmentsDir.path}/latest_phone_capture.jpg');
    await file.writeAsBytes(bytes, flush: true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(attachedImagePathKey, file.path);

    return file.path;
  }

  Future<void> _restoreAttachedImage() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString(attachedImagePathKey);
    if (savedPath == null) {
      return;
    }

    final file = File(savedPath);
    if (!await file.exists()) {
      await prefs.remove(attachedImagePathKey);
      return;
    }

    final bytes = await file.readAsBytes();
    if (!mounted) {
      return;
    }

    setState(() {
      _attachedImagePath = savedPath;
      _capturedImage = bytes;
      _previewSource = _PreviewSource.phoneAttachment;
    });
  }

  Future<void> _recoverLostPhoneCapture() async {
    final response = await _imagePicker.retrieveLostData();
    if (response.isEmpty) {
      return;
    }

    final files = response.files;
    if (files != null && files.isNotEmpty) {
      await _attachPhoneImage(files.first, announce: false);
      _setStatus('Recovered phone image', _AppState.idle);
      return;
    }

    if (response.exception != null) {
      debugPrint(
        '[PHONE-CAMERA] Lost data recovery error: ${response.exception}',
      );
    }
  }

  Future<void> _clearAttachedImage({bool deleteFile = true}) async {
    final path = _attachedImagePath;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(attachedImagePathKey);

    if (deleteFile && path != null) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _attachedImagePath = null;
      if (_previewSource == _PreviewSource.phoneAttachment) {
        _capturedImage = null;
        _previewSource = _PreviewSource.none;
      }
    });
  }

  Future<Uint8List?> _captureEsp32Image() async {
    final bytes = await _apiService.captureImage();
    if (bytes == null) {
      await _speak('Could not reach the camera.');
      return null;
    }

    if (!mounted) {
      return bytes;
    }

    setState(() {
      _capturedImage = bytes;
      _previewSource = _PreviewSource.esp32;
    });

    return bytes;
  }

  Future<Uint8List?> _getImageForRequest() async {
    if (_attachedImagePath != null) {
      try {
        final bytes = await File(_attachedImagePath!).readAsBytes();
        if (mounted) {
          setState(() {
            _capturedImage = bytes;
            _previewSource = _PreviewSource.phoneAttachment;
          });
        }
        return bytes;
      } catch (error) {
        debugPrint('[ATTACHMENT] Failed to read attached image: $error');
        await _clearAttachedImage(deleteFile: false);
      }
    }

    return _captureEsp32Image();
  }

  Future<String?> _saveBytesToFile(Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/smart_glass_capture_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (error) {
      debugPrint('[FILE] Error saving temp file: $error');
      return null;
    }
  }

  void _cleanup(List<String?> paths) {
    for (final path in paths) {
      if (path == null) {
        continue;
      }

      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _onSpeechResult(String rawText) async {
    final text = rawText.toLowerCase().trim();
    if (text.isEmpty) {
      _setStatus('Ready - tap the mic.', _AppState.idle);
      await _resumeWakeWordIfIdle();
      return;
    }

    await _speech.stop();

    if (_isWaitingForDescription) {
      _isWaitingForDescription = false;
      final description = text.contains('no') && text.split(' ').length <= 3
          ? ''
          : rawText.trim();
      await _executeRegistration(_pendingName, description);
      return;
    }

    if (_matchesFaceRegister(text)) {
      final extractedName = _extractName(rawText);

      if (mounted) {
        setState(() {
          _pendingName = extractedName;
          _isWaitingForDescription = true;
        });
      }

      _setStatus(
        'Say description -> $extractedName',
        _AppState.awaitingDescription,
      );
      await _speakAndWait(
        'I heard $extractedName. Please say a description for this person, or say no.',
      );

      if (!_speech.isAvailable) {
        await _speech.initialize(
          onError: (error) => debugPrint('[STT] Error: ${error.errorMsg}'),
        );
      }

      _listenForSpeech();
      return;
    }

    if (_matchesFaceRecognize(text)) {
      await _handleFaceRecognition();
      return;
    }

    await _handleGeminiVision(rawText);
  }

  bool _matchesFaceRegister(String text) {
    return RegExp(
      r'\b(?:mark|save|remember|register|store|add|name|tag|label)\b'
      r'.*'
      r'\b(?:person|face|this\s+is|him|her|as\b)',
    ).hasMatch(text);
  }

  bool _matchesFaceRecognize(String text) {
    return RegExp(
      r'\b(?:'
      r'who\s+(?:is|are)\s+(?:this|that|the)'
      r'|who\s*(?:am\s*i|are\s*we)\s+(?:speaking|talking|looking|standing)'
      r'|who\s+is\s+(?:in\s+front|near|before|beside)'
      r'|whose\s+face'
      r'|recognize\s+(?:this|the|that)'
      r'|identify\s+(?:this|the|that)\s+(?:person|face|man|woman|guy|girl)'
      r'|do\s+you\s+(?:know|recognize|recognise)'
      r'|who\s+is\s+(?:he|she|this\s+person|that\s+person)'
      r'|tell\s+me\s+who'
      r')\b',
    ).hasMatch(text);
  }

  String _extractName(String transcript) {
    final words = transcript.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) {
      return 'Unknown';
    }

    for (var index = 0; index < words.length - 1; index++) {
      final word = words[index].toLowerCase();
      if (word == 'as' || word == 'us') {
        return words.sublist(index + 1).join(' ');
      }
    }

    return words.last;
  }

  Future<void> _handleFaceRecognition() async {
    _setStatus(
      _hasAttachedImage ? 'Using attached photo...' : 'Capturing image...',
      _AppState.processing,
    );

    await _speakAndWait(
      _hasAttachedImage
          ? 'Let me check the attached photo.'
          : 'Let me check who is in front of you.',
    );

    final bytes = await _getImageForRequest();
    if (bytes == null) {
      _setStatus('Camera error', _AppState.idle);
      await _resumeWakeWordIfIdle();
      return;
    }

    final imagePath = await _saveBytesToFile(bytes);
    if (imagePath == null) {
      _setStatus('File error', _AppState.idle);
      await _resumeWakeWordIfIdle();
      return;
    }

    _setStatus('Scanning for faces...', _AppState.processing);
    final cropPath = await _faceService.detectAndCropFace(imagePath);

    if (cropPath == null) {
      const message = 'I do not see anyone in this image.';
      if (mounted) {
        setState(() => _serverResponse = message);
      }
      _setStatus('No face detected', _AppState.idle);
      await _speak(message);
      _cleanup([imagePath]);
      await _resumeWakeWordIfIdle();
      return;
    }

    _setStatus('Identifying...', _AppState.processing);
    try {
      final embedding = _faceService.getEmbedding(cropPath);
      final match = _faceService.recognizeFace(embedding);

      final message = match != null
          ? (match['description']?.isNotEmpty == true
                ? 'This is ${match['name']}. ${match['description']}.'
                : 'This is ${match['name']}.')
          : 'I see a person, but I do not recognize them.';

      if (mounted) {
        setState(() => _serverResponse = message);
      }
      _setStatus('Done', _AppState.idle);
      await _speak(message);
    } catch (error) {
      if (mounted) {
        setState(() => _serverResponse = 'Face recognition error.');
      }
      _setStatus('Error', _AppState.idle);
      await _speak('An error occurred during face recognition.');
      debugPrint('[RECOGNIZE] Error: $error');
    } finally {
      _cleanup([imagePath, cropPath]);
      await _resumeWakeWordIfIdle();
    }
  }

  Future<void> _executeRegistration(String name, String description) async {
    _setStatus(
      _hasAttachedImage ? 'Using attached photo...' : 'Capturing image...',
      _AppState.processing,
    );

    await _speakAndWait(
      _hasAttachedImage
          ? 'Registering from the attached photo.'
          : 'Registering. Please hold still.',
    );

    final bytes = await _getImageForRequest();
    if (bytes == null) {
      _pendingName = '';
      _setStatus('Camera error', _AppState.idle);
      await _resumeWakeWordIfIdle();
      return;
    }

    final imagePath = await _saveBytesToFile(bytes);
    if (imagePath == null) {
      _pendingName = '';
      _setStatus('File error', _AppState.idle);
      await _resumeWakeWordIfIdle();
      return;
    }

    _setStatus('Detecting face...', _AppState.processing);
    final cropPath = await _faceService.detectAndCropFace(imagePath);

    if (cropPath == null) {
      const message = 'I could not detect a face. Please try again.';
      if (mounted) {
        setState(() => _serverResponse = message);
      }
      _pendingName = '';
      _setStatus('No face', _AppState.idle);
      await _speak(message);
      _cleanup([imagePath]);
      await _resumeWakeWordIfIdle();
      return;
    }

    _setStatus('Saving $name...', _AppState.processing);
    try {
      final embedding = _faceService.getEmbedding(cropPath);
      await _faceService.registerFace(
        name: name,
        description: description,
        embedding: embedding,
        cropPath: cropPath,
      );

      final descriptionPart = description.isNotEmpty
          ? ' Description: $description.'
          : '';
      final message = 'Successfully registered $name.$descriptionPart';

      if (mounted) {
        setState(() {
          _serverResponse = message;
          _pendingName = '';
        });
      }
      _setStatus('Registered: $name', _AppState.idle);
      await _speak(message);
    } catch (error) {
      if (mounted) {
        setState(() {
          _serverResponse = 'Registration failed.';
          _pendingName = '';
        });
      }
      _setStatus('Error', _AppState.idle);
      await _speak('Registration failed. Please try again.');
      debugPrint('[REGISTER] Error: $error');
    } finally {
      _cleanup([imagePath, cropPath]);
      await _resumeWakeWordIfIdle();
    }
  }

  Future<void> _handleGeminiVision(String query) async {
    _setStatus(
      _hasAttachedImage ? 'Using attached photo...' : 'Capturing image...',
      _AppState.processing,
    );

    await _speakAndWait(
      _hasAttachedImage
          ? 'Analyzing the attached photo.'
          : 'Analyzing the scene.',
    );

    final bytes = await _getImageForRequest();
    if (bytes == null) {
      _setStatus('Camera error', _AppState.idle);
      await _resumeWakeWordIfIdle();
      return;
    }

    _setStatus('Asking Gemini...', _AppState.processing);
    final response = await _apiService.analyzeImage(bytes, query);

    if (mounted) {
      setState(() => _serverResponse = response);
    }
    _setStatus('Done', _AppState.idle);
    await _speak(response);
    await _resumeWakeWordIfIdle();
  }

  Future<void> _cancelListening() async {
    await _speech.stop();
    if (mounted) {
      setState(() {
        _isWaitingForDescription = false;
        _pendingName = '';
      });
    }
    _setStatus('Cancelled', _AppState.idle);
    await _speak('Stopped.');
    await _resumeWakeWordIfIdle();
  }

  @override
  Widget build(BuildContext context) {
    final isActive =
        _appState == _AppState.listening ||
        _appState == _AppState.awaitingDescription;
    final isProcessing = _appState == _AppState.processing;
    final cameraActionDisabled = isActive || isProcessing;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text(
          'Smart Glass Assistant',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: const [
                Icon(Icons.cloud_done, color: Colors.green, size: 16),
                SizedBox(width: 6),
                Text(
                  'Gemini Direct (no backend)',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  _wakeWordReady && _wakeWordRunning
                      ? Icons.hearing
                      : Icons.hearing_disabled,
                  color: _wakeWordReady && _wakeWordRunning
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _wakeWordMessage,
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildStatusChip(),
            const SizedBox(height: 16),
            _buildCameraControls(cameraActionDisabled),
            const SizedBox(height: 20),
            _buildImagePreview(),
            const SizedBox(height: 12),
            Text(
              _previewDescription(),
              style: const TextStyle(color: Colors.grey, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (_lastQuery.isNotEmpty) ...[
              const Text(
                'You said:',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                '"$_lastQuery"',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_serverResponse.isNotEmpty) ...[
              const Text(
                'AI Response:',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                _serverResponse,
                style: const TextStyle(
                  color: Color(0xFF58A6FF),
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
                  : isActive
                  ? Colors.red.shade700
                  : const Color(0xFF238636),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            onPressed: isProcessing
                ? null
                : isActive
                ? _cancelListening
                : () => _startListening(),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isProcessing
                      ? Icons.hourglass_top
                      : isActive
                      ? Icons.mic_off
                      : Icons.mic,
                  size: 36,
                  color: Colors.white,
                ),
                const SizedBox(height: 8),
                Text(
                  isProcessing
                      ? 'Processing...'
                      : isActive
                      ? 'Tap to Cancel'
                      : 'Ask Question',
                  style: const TextStyle(fontSize: 26, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCameraControls(bool disabled) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: disabled ? null : _capturePhoneImage,
            icon: const Icon(Icons.photo_camera_back),
            label: Text(
              _hasAttachedImage ? 'Retake Phone Photo' : 'Phone Camera',
            ),
          ),
        ),
        if (_hasAttachedImage) ...[
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: disabled ? null : () => _clearAttachedImage(),
            icon: const Icon(Icons.close),
            label: const Text('Clear'),
          ),
        ],
      ],
    );
  }

  Widget _buildStatusChip() {
    late final Color chipColor;
    switch (_appState) {
      case _AppState.idle:
        chipColor = Colors.green.shade700;
        break;
      case _AppState.listening:
        chipColor = Colors.blue.shade700;
        break;
      case _AppState.awaitingDescription:
        chipColor = Colors.amber.shade700;
        break;
      case _AppState.processing:
        chipColor = Colors.purple.shade700;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.2),
        border: Border.all(color: chipColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (_appState == _AppState.processing)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            Icon(_stateIcon(), color: Colors.white, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _statusText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _stateIcon() {
    switch (_appState) {
      case _AppState.idle:
        return Icons.check_circle_outline;
      case _AppState.listening:
        return Icons.mic;
      case _AppState.awaitingDescription:
        return Icons.record_voice_over;
      case _AppState.processing:
        return Icons.hourglass_top;
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
          Text(
            'No image captured yet',
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }

  String _previewDescription() {
    switch (_previewSource) {
      case _PreviewSource.phoneAttachment:
        return 'Current source: attached phone-camera image.';
      case _PreviewSource.esp32:
        return 'Current source: latest ESP32-CAM capture.';
      case _PreviewSource.none:
        return 'Ask a question to use ESP32-CAM, or attach a photo from the phone camera.';
    }
  }
}

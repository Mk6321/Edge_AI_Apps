import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

class VoskWakeWordStatus {
  const VoskWakeWordStatus({
    required this.ready,
    required this.listening,
    required this.message,
  });

  final bool ready;
  final bool listening;
  final String message;
}

class VoskService {
  VoskService();

  static const String _modelAssetPath = 'assets/models/vosk_model';
  static const int _sampleRate = 16000;
  static const List<String> _wakePhrases = <String>['hey glass'];

  final _wakeWordController = StreamController<String>.broadcast();
  final _statusController = StreamController<VoskWakeWordStatus>.broadcast();

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();

  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;
  StreamSubscription<String>? _partialSubscription;
  StreamSubscription<String>? _resultSubscription;

  bool _initialized = false;
  bool _listening = false;
  bool _handoffInProgress = false;

  Stream<String> get onWakeWordDetected => _wakeWordController.stream;
  Stream<VoskWakeWordStatus> get onStatusChanged => _statusController.stream;

  bool get isReady => _initialized;
  bool get isListening => _listening;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    _emitStatus(
      ready: false,
      listening: false,
      message: 'Preparing offline wake word...',
    );

    final modelPath = await _extractModelToLocal();
    _model = await _vosk.createModel(modelPath);
    _recognizer = await _vosk.createRecognizer(
      model: _model!,
      sampleRate: _sampleRate,
      grammar: _wakePhrases,
    );
    _speechService = await _vosk.initSpeechService(_recognizer!);

    _partialSubscription = _speechService!.onPartial().listen(
      _handleSpeechText,
    );
    _resultSubscription = _speechService!.onResult().listen(_handleSpeechText);

    _initialized = true;
    _emitStatus(
      ready: true,
      listening: false,
      message: 'Offline wake word ready.',
    );
  }

  Future<void> startListening() async {
    if (!_initialized || _speechService == null || _listening) {
      return;
    }

    _handoffInProgress = false;
    await _speechService!.start(
      onRecognitionError: (Object error) {
        _listening = false;
        debugPrint('ERROR: $error');
        _emitStatus(
          ready: _initialized,
          listening: false,
          message: 'Wake word paused.',
        );
      },
    );
    _listening = true;
    _emitStatus(
      ready: true,
      listening: true,
      message: 'Wake word listening.',
    );
  }

  Future<void> pauseListening() async {
    if (!_initialized || _speechService == null || !_listening) {
      return;
    }

    await _speechService!.stop();
    _listening = false;
    _emitStatus(ready: true, listening: false, message: 'Wake word paused.');
  }

  Future<void> resumeListening() async {
    if (!_initialized || _speechService == null || _listening) {
      return;
    }

    _handoffInProgress = false;
    await _speechService!.reset();
    await startListening();
  }

  Future<void> dispose() async {
    await _partialSubscription?.cancel();
    await _resultSubscription?.cancel();
    await _speechService?.stop();
    await _speechService?.dispose();
    await _recognizer?.dispose();
    _model?.dispose();
    await _wakeWordController.close();
    await _statusController.close();
  }

  void _handleSpeechText(String raw) {
    if (_handoffInProgress) {
      return;
    }

    final normalized = _extractTranscript(raw);
    if (normalized.isEmpty) {
      return;
    }

    for (final phrase in _wakePhrases) {
      if (normalized.contains(phrase)) {
        unawaited(_triggerWakeWord(phrase));
        return;
      }
    }
  }

  Future<void> _triggerWakeWord(String phrase) async {
    if (_handoffInProgress) {
      return;
    }

    _handoffInProgress = true;
    await pauseListening();
    _wakeWordController.add(phrase);
    _emitStatus(
      ready: true,
      listening: false,
      message: 'Wake word detected: $phrase',
    );
  }

  String _extractTranscript(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        final text = decoded['text'] ?? decoded['partial'];
        if (text is String) {
          return text.toLowerCase().trim();
        }
      }
    } catch (_) {}

    return trimmed.toLowerCase();
  }

  void _emitStatus({
    required bool ready,
    required bool listening,
    required String message,
  }) {
    if (_statusController.isClosed) {
      return;
    }

    _statusController.add(
      VoskWakeWordStatus(ready: ready, listening: listening, message: message),
    );
  }

  Future<String> _extractModelToLocal() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets =
        manifest
            .listAssets()
            .where((path) => path.startsWith('$_modelAssetPath/'))
            .toList()
          ..sort();

    final docsDir = await getApplicationDocumentsDirectory();
    final targetRoot = Directory('${docsDir.path}/vosk_model');
    final readyMarker = File('${targetRoot.path}/conf/model.conf');

    if (await readyMarker.exists() && assets.isNotEmpty) {
      return targetRoot.path;
    }

    if (!await targetRoot.exists()) {
      await targetRoot.create(recursive: true);
    }

    if (assets.isEmpty) {
      throw Exception(
        'VOSK model assets were not found under $_modelAssetPath. '
        'Make sure every model subfolder is declared in pubspec.yaml.',
      );
    }

    for (final asset in assets) {
      final relativePath = asset.replaceFirst('$_modelAssetPath/', '');
      final outFile = File('${targetRoot.path}/$relativePath');
      await outFile.parent.create(recursive: true);
      final byteData = await rootBundle.load(asset);
      await outFile.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
        flush: true,
      );
    }

    if (!await readyMarker.exists()) {
      throw Exception(
        'VOSK model copy completed, but conf/model.conf was not found.',
      );
    }

    return targetRoot.path;
  }
}

import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

class VoiceService {
  late stt.SpeechToText _speech;
  late FlutterTts _flutterTts;
  bool _isListening = false;
  
  bool get isListening => _isListening;

  Future<void> init() async {
    _speech = stt.SpeechToText();
    _flutterTts = FlutterTts();
    
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setPitch(1.0);
    // await _flutterTts.setSpeechRate(0.5); // Default is usually fine
  }

  Future<bool> startListening(Function(String) onResult) async {
    bool available = await _speech.initialize(
      onStatus: (val) => print('onStatus: $val'),
      onError: (val) => print('onError: $val'),
    );
    
    if (available) {
      _isListening = true;
      _speech.listen(
        onResult: (val) {
           if (val.finalResult) {
             _isListening = false;
             onResult(val.recognizedWords);
           }
        }
      );
      return true;
    }
    return false;
  }

  Future<void> stopListening() async {
    _isListening = false;
    await _speech.stop();
  }

  Future<void> speak(String text) async {
    await _flutterTts.speak(text);
  }
  
  Future<void> stopSpeaking() async {
    await _flutterTts.stop();
  }
}

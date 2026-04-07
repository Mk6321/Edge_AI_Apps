import 'dart:typed_data';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;

/// API service for Smart Glass — now calls Gemini DIRECTLY from the app.
///
/// ╔═══════════════════════════════════════════════════════════╗
/// ║  NO BACKEND SERVER. NO NGROK. NO LAPTOP REQUIRED.        ║
/// ║  Gemini API key is embedded in the app.                  ║
/// ║  Face recognition is handled by FaceService (separate).  ║
/// ╚═══════════════════════════════════════════════════════════╝
class ApiService {
  // ── CONFIGURATION ──────────────────────────────────────────────────────────
  /// Your Gemini API key — embedded directly in the app.
  static const String _geminiApiKey = 'AIzaSyCeePRv_oEeQzyGfgpMKgBhcPfPSaFC1vw';

  /// ESP32-CAM capture URL.
  static const String _esp32Url = 'http://10.235.89.20/capture';

  // ── Gemini Model ───────────────────────────────────────────────────────────
  late final GenerativeModel _model;

  // ── System Prompts ─────────────────────────────────────────────────────────
  static const String _visionSystemPrompt =
      'You are a spatial awareness assistant for a visually impaired user. '
      'Describe the objects and environment concisely. '
      'CRITICAL: If you see labels, brands, or text, DO NOT GUESS. '
      'If you cannot read it clearly, say "There is text I cannot read." '
      'Do not invent names.';

  static const String _ocrSystemPrompt =
      'You are a text extraction engine. Read and return ALL text visible in '
      'this image. Output the raw text only, no commentary.';

  static const String _currencySystemPrompt =
      'You are a financial detection engine. Output ONLY the number and the '
      'currency type (e.g., "100 Rupees"). Do not write full sentences.';

  // ---------------------------------------------------------------------------
  // INIT
  // ---------------------------------------------------------------------------

  Future<void> init() async {
    _model = GenerativeModel(
      model: 'gemini-2.5-flash',
      apiKey: _geminiApiKey,
    );
    print('[API] Gemini model initialized (gemini-2.5-flash, direct SDK).');
  }

  // ---------------------------------------------------------------------------
  // IMAGE CAPTURE (ESP32-CAM — unchanged)
  // ---------------------------------------------------------------------------

  /// Captures a JPEG frame from the ESP32-CAM.
  Future<Uint8List?> captureImage() async {
    try {
      print('[ESP32] GET $_esp32Url');
      final response = await http
          .get(Uri.parse(_esp32Url))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        print('[ESP32] Captured ${response.bodyBytes.length} bytes.');
        return response.bodyBytes;
      } else {
        print('[ESP32] Error: status ${response.statusCode}');
      }
    } catch (e) {
      print('[ESP32] Exception: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // GEMINI VISION — replaces /analyze endpoint
  // ---------------------------------------------------------------------------

  /// Sends image + query directly to Gemini. No backend needed.
  Future<String> analyzeImage(Uint8List imageBytes, String query) async {
    try {
      print('[GEMINI] Analyzing image — query: "$query"');

      // Pick system prompt based on query keywords
      final systemPrompt = _pickSystemPrompt(query);

      final response = await _model.generateContent([
        Content.multi([
          TextPart('$systemPrompt\n\nUser query: $query'),
          DataPart('image/jpeg', imageBytes),
        ]),
      ]);

      final text = response.text ?? 'No response generated.';
      print('[GEMINI] Response: $text');
      return text;
    } catch (e) {
      print('[GEMINI] Error: $e');
      if (e.toString().contains('quota') || e.toString().contains('429')) {
        return 'API quota exceeded. Please wait a moment and try again.';
      }
      return 'Gemini error: $e';
    }
  }

  // ---------------------------------------------------------------------------
  // SYSTEM PROMPT SELECTION
  // ---------------------------------------------------------------------------

  String _pickSystemPrompt(String query) {
    final q = query.toLowerCase();

    // Currency detection
    if (RegExp(r'\b(?:rupee|rupees|money|note|notes|coin|coins|currency|cash|denomination)\b')
        .hasMatch(q)) {
      return _currencySystemPrompt;
    }

    // OCR / text reading
    if (RegExp(r'\b(?:read|text|passage|document|words?|letters?|sign|says|written)\b')
        .hasMatch(q)) {
      return _ocrSystemPrompt;
    }

    // Default: scene description
    return _visionSystemPrompt;
  }
}

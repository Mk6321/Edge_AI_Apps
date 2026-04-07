/// Local keyword-based intent router.
/// Categorises the user's spoken text to decide which model to invoke:
///   - ML Kit OCR (for text-reading requests)
///   - ML Kit Face Detection + MobileFaceNet (for face recognition/registration)
///   - LFM2-VL (for scene description, object identification, currency, etc.)
///
/// No API calls — pure string matching with RegExp.
class IntentRouter {
  IntentRouter._();

  // ── Sentinel triggers ──────────────────────────────────────────────────────
  /// Returned when ML Kit OCR should handle the request.
  static const String mlKitOcrTrigger = 'TRIGGER_ML_KIT_OCR';

  /// Returned when face recognition should be performed.
  static const String faceRecognizeTrigger = 'TRIGGER_FACE_RECOGNIZE';

  /// Returned when face registration should begin.
  static const String faceRegisterTrigger = 'TRIGGER_FACE_REGISTER';

  // ── System prompts for LFM2-VL ─────────────────────────────────────────────
  /// System prompt for currency/denomination detection.
  static const String currencySystemPrompt =
      'SYSTEM: You are a financial detection engine. Output ONLY the number '
      'and the currency type (e.g., "100 Rupees"). Do not write full sentences.';

  /// Default system prompt for general scene description.
  static const String generalSystemPrompt =
      'SYSTEM: You are a spatial awareness assistant for a visually impaired '
      'user. Describe the objects and environment concisely. CRITICAL: If you '
      'see labels, brands, or text, DO NOT GUESS. If you cannot read it '
      'clearly, say "There is text I cannot read." Do not invent names.';

  // ── Regex patterns ─────────────────────────────────────────────────────────

  /// Face REGISTRATION triggers (must come before recognition in priority).
  /// Matches: "mark/save/remember/register/store ... person/face/this is/him/her"
  static final RegExp _faceRegisterPattern = RegExp(
    r'\b(?:mark|save|remember|register|store|add|name|tag|label)\b'
    r'.*'
    r'\b(?:person|face|this\s+is|him|her|as\b)',
  );

  /// Face RECOGNITION triggers.
  /// Matches: "who is this", "who am I speaking to", "whose face", "recognize",
  ///          "identify this person", "do you know this person", etc.
  static final RegExp _faceRecognizePattern = RegExp(
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
  );

  /// OCR / text reading triggers.
  static final RegExp _ocrPattern = RegExp(
    r'\b(?:read|extract(?:ion|ing|ed)?|text|passage|document|words?|letters?|sign|says|written)\b',
  );

  /// Currency / money triggers.
  static final RegExp _currencyPattern = RegExp(
    r'\b(?:rupee|rupees|money|note|notes|coin|coins|currency|cash|denomination|denominations)\b',
  );

  // ── Main router ────────────────────────────────────────────────────────────

  /// Returns the appropriate trigger or system prompt for the given transcript.
  ///
  /// Priority order:
  ///   1. Face Registration (highest — explicit user action)
  ///   2. Face Recognition
  ///   3. Currency detection
  ///   4. OCR / text reading
  ///   5. General vision (catch-all)
  static String getSystemPrompt(String transcript) {
    final normalized = transcript.trim().toLowerCase();
    if (normalized.isEmpty) return generalSystemPrompt;

    if (_faceRegisterPattern.hasMatch(normalized)) return faceRegisterTrigger;
    if (_faceRecognizePattern.hasMatch(normalized)) return faceRecognizeTrigger;
    if (_currencyPattern.hasMatch(normalized))      return currencySystemPrompt;
    if (_ocrPattern.hasMatch(normalized))            return mlKitOcrTrigger;

    return generalSystemPrompt;
  }

  /// Extracts the person's name from a registration command.
  /// Takes the last word after "as" if present, otherwise the last word.
  static String extractName(String transcript) {
    final words = transcript.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return 'Unknown';

    // Try to find "as <name>" pattern
    for (int i = 0; i < words.length - 1; i++) {
      if (words[i].toLowerCase() == 'as' || words[i].toLowerCase() == 'us') {
        // Return everything after "as" joined
        return words.sublist(i + 1).join(' ');
      }
    }

    // Fallback: last word
    return words.last;
  }
}

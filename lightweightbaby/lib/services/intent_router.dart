class IntentRouter {
  IntentRouter._();

  static const String mlKitOcrTrigger = 'TRIGGER_ML_KIT_OCR';
  static const String faceApiTrigger = 'TRIGGER_SERVER_FACE_API';
  static const String currencySystemPrompt =
      'SYSTEM: You are a financial detection engine. Output ONLY the number and the currency type (e.g., "100 Rupees"). Do not write full sentences.';
  static const String generalSystemPrompt =
      'SYSTEM: You are a spatial awareness assistant for a visually impaired user. Describe the objects and environment concisely. CRITICAL: If you see labels, brands, or text, DO NOT GUESS. If you cannot read it clearly, say "There is text I cannot read." Do not invent names.';

  static final RegExp _ocrPattern = RegExp(
    r'\b(?:read|extract(?:ion|ing|ed)?|text|passage|document|words?|letters?|sign|says|written)\b',
  );
  static final RegExp _facePattern = RegExp(
    r'\b(?:who|person|people|face|man|woman|guy|girl)\b',
  );
  static final RegExp _currencyPattern = RegExp(
    r'\b(?:rupee|rupees|money|note|notes|coin|coins|currency|cash|denomination|denominations)\b',
  );

  static String getSystemPrompt(String transcript) {
    final normalized = transcript.trim().toLowerCase();
    if (normalized.isEmpty) {
      return generalSystemPrompt;
    }

    // Prefer currency over OCR because prompts like "read this note" often
    // refer to cash, and specific tool routes should win over generic verbs.
    if (_currencyPattern.hasMatch(normalized)) {
      return currencySystemPrompt;
    }
    if (_ocrPattern.hasMatch(normalized)) {
      return mlKitOcrTrigger;
    }
    if (_facePattern.hasMatch(normalized)) {
      return faceApiTrigger;
    }

    return generalSystemPrompt;
  }
}

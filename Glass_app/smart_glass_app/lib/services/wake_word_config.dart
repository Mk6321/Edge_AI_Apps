class WakeWordConfig {
  const WakeWordConfig._();

  static const String accessKey = String.fromEnvironment(
    'PICOVOICE_ACCESS_KEY',
    defaultValue: '',
  );

  static const String customKeywordAssetPath = String.fromEnvironment(
    'PICOVOICE_KEYWORD_ASSET',
    defaultValue: '',
  );

  static const double sensitivity = 0.65;
  static const String fallbackWakePhrase = 'Jarvis';
  static const String preferredWakePhrase = 'Hey Jarvis';

  static bool get hasAccessKey => accessKey.trim().isNotEmpty;
  static bool get hasCustomKeyword => customKeywordAssetPath.trim().isNotEmpty;
}

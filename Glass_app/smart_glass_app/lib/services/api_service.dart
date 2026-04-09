import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// API service for Smart Glass.
///
/// Scene analysis uses NVIDIA's hosted Phi-3.5 Vision Instruct model.
class ApiService {
  static const String _nvidiaApiKey = String.fromEnvironment(
    'NVIDIA_API_KEY',
    defaultValue:
        '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',
  );

  static const String _nvidiaEndpoint =
      'https://integrate.api.nvidia.com/v1/chat/completions';
  static const String _nvidiaModel = 'microsoft/phi-3.5-vision-instruct';
  static const String _esp32Url = 'http://10.235.89.20/capture';

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
      'currency type (for example "100 Rupees"). Do not write full sentences.';

  Future<void> init() async {}

  Future<Uint8List?> captureImage() async {
    try {
      final response = await http
          .get(Uri.parse(_esp32Url))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      debugPrint('ERROR: ESP32 returned status ${response.statusCode}');
    } catch (error) {
      debugPrint('ERROR: $error');
    }
    return null;
  }

  Future<String> analyzeImage(Uint8List imageBytes, String query) async {
    if (_isOcrQuery(query)) {
      return _extractTextLocally(imageBytes);
    }

    final systemPrompt = _pickSystemPrompt(query);
    final base64Image = base64Encode(imageBytes);

    try {
      final response = await http
          .post(
            Uri.parse(_nvidiaEndpoint),
            headers: {
              'Authorization': 'Bearer $_nvidiaApiKey',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'model': _nvidiaModel,
              'stream': false,
              'max_tokens': 250,
              'temperature': 0.2,
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'text',
                      'text': '$systemPrompt\n\nUser query: $query',
                    },
                    {
                      'type': 'image_url',
                      'image_url': {
                        'url': 'data:image/jpeg;base64,$base64Image',
                      },
                    },
                  ],
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));

      final body = _decodeJsonBody(response.body);

      if (response.statusCode >= 400) {
        final detail = body?['detail'];
        final title = body?['title'];
        final message =
            detail?.toString() ??
            title?.toString() ??
            _plainErrorText(response.body) ??
            'Request failed.';
        debugPrint(
          'ERROR: Vision request failed with status ${response.statusCode}: $message',
        );
        return '';
      }

      if (body == null) {
        debugPrint('ERROR: Vision API returned invalid response format.');
        return '';
      }

      final choices = body['choices'];
      if (choices is! List || choices.isEmpty) {
        return 'No response generated.';
      }

      final message = choices.first['message'];
      final content = message is Map<String, dynamic>
          ? message['content']
          : null;
      final text = _extractTextContent(content);
      return text.isEmpty ? 'No response generated.' : text;
    } on SocketException {
      debugPrint('ERROR: Vision API network error.');
      return '';
    } on FormatException {
      debugPrint('ERROR: Vision API returned an unexpected response.');
      return '';
    } catch (error) {
      debugPrint('ERROR: $error');
      return '';
    }
  }

  Map<String, dynamic>? _decodeJsonBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (error) {
      debugPrint('ERROR: $error');
    }
    return null;
  }

  Future<String> _extractTextLocally(Uint8List imageBytes) async {
    final textRecognizer = TextRecognizer(
      script: TextRecognitionScript.devanagiri,
    );
    String? tempPath;

    try {
      final tempDir = await getTemporaryDirectory();
      tempPath =
          '${tempDir.path}/smart_glass_ocr_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final file = File(tempPath);
      await file.writeAsBytes(imageBytes, flush: true);

      final inputImage = InputImage.fromFilePath(file.path);
      final recognizedText = await textRecognizer.processImage(inputImage);
      final text = recognizedText.text.trim();
      return text.isEmpty ? 'No text found in the image.' : text;
    } catch (error) {
      debugPrint('ERROR: $error');
      return '';
    } finally {
      await textRecognizer.close();
      if (tempPath != null) {
        try {
          final file = File(tempPath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
    }
  }

  String? _plainErrorText(String body) {
    final cleaned = body.trim();
    if (cleaned.isEmpty) {
      return null;
    }
    return cleaned.length > 180 ? '${cleaned.substring(0, 180)}...' : cleaned;
  }

  String _extractTextContent(dynamic content) {
    if (content is String) {
      return content.trim();
    }

    if (content is List) {
      final parts = <String>[];
      for (final entry in content) {
        if (entry is Map<String, dynamic>) {
          final text = entry['text'];
          if (text is String && text.trim().isNotEmpty) {
            parts.add(text.trim());
          }
        }
      }
      return parts.join('\n').trim();
    }

    return '';
  }

  bool _isOcrQuery(String query) {
    final q = query.toLowerCase();
    return RegExp(
      r'\b(?:read|extract(?:ion|ing|ed)?|text|passage|document|words?|letters?|sign|says|written)\b',
    ).hasMatch(q);
  }

  String _pickSystemPrompt(String query) {
    final q = query.toLowerCase();

    if (RegExp(
      r'\b(?:rupee|rupees|money|note|notes|coin|coins|currency|cash|denomination)\b',
    ).hasMatch(q)) {
      return _currencySystemPrompt;
    }

    if (_isOcrQuery(q)) {
      return _ocrSystemPrompt;
    }

    return _visionSystemPrompt;
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Captures JPEG images from the ESP32-CAM and saves them as temporary files.
///
/// Both LFM2-VL (via [LlamaImageContent]) and Google ML Kit require a file
/// path, not raw bytes, so this service bridges that gap.
class Esp32Service {
  final String captureUrl;

  Esp32Service({required this.captureUrl});

  /// Hits the ESP32-CAM /capture endpoint, saves the JPEG to a temp file,
  /// and returns the absolute file path.
  ///
  /// Returns `null` if the camera is unreachable or returns an error status.
  Future<String?> captureToFile() async {
    try {
      print('[ESP32] GET $captureUrl');
      final response = await http
          .get(Uri.parse(captureUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        print('[ESP32] ERROR — status ${response.statusCode}');
        return null;
      }

      final Uint8List bytes = response.bodyBytes;
      print('[ESP32] Received ${bytes.length} bytes');

      // Save to a temp file so LFM2-VL and ML Kit can read it
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${tempDir.path}/esp32_capture_$timestamp.jpg';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      print('[ESP32] Saved to $filePath');
      return filePath;
    } catch (e) {
      print('[ESP32] Exception: $e');
      return null;
    }
  }

  /// Returns the raw JPEG bytes from the ESP32-CAM for UI display.
  Future<Uint8List?> captureBytes() async {
    try {
      final response = await http
          .get(Uri.parse(captureUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) return response.bodyBytes;
    } catch (e) {
      print('[ESP32] captureBytes error: $e');
    }
    return null;
  }
}

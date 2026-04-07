import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class FaceVaultEntry {
  const FaceVaultEntry({
    required this.name,
    required this.description,
    required this.imagePaths,
    required this.registeredAt,
  });

  final String name;
  final String description;
  final List<String> imagePaths;
  final DateTime? registeredAt;
}

/// On-device face recognition engine.
///
/// **Stage 1 (Finder):** Google ML Kit Face Detection — detects faces, crops.
/// **Stage 2 (Identifier):** MobileFaceNet TFLite — 192-d embedding + vault comparison.
///
/// All data stored locally: `face_vault.json` (metadata) + `face_embeddings.json` (vectors).
class FaceService {
  // ── ML Kit Face Detector ──
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: false,
      enableContours: false,
      enableClassification: false,
      enableTracking: false,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.15,
    ),
  );

  // ── MobileFaceNet TFLite ──
  Interpreter? _interpreter;
  static const int _inputSize = 112; // MobileFaceNet expects 112x112
  static const int _embeddingSize = 192; // This model outputs 192-d (not 128)
  static const double _matchThreshold = 1.0; // Euclidean distance threshold

  // ── Face Vault (local JSON storage) ──
  Map<String, dynamic> _vault = {};
  Map<String, List<List<double>>> _embeddings = {};

  bool _initialized = false;
  bool get isReady => _initialized;

  List<FaceVaultEntry> getRegisteredFaces() {
    final entries = <FaceVaultEntry>[];

    for (final entry in _vault.entries) {
      final raw = entry.value;
      if (raw is! Map<String, dynamic>) {
        continue;
      }

      final images =
          (raw['images'] as List?)
              ?.map((value) => value.toString())
              .where((value) => value.isNotEmpty)
              .toList() ??
          <String>[];

      final registeredAtRaw = raw['registered_at']?.toString();
      entries.add(
        FaceVaultEntry(
          name: entry.key,
          description: raw['description']?.toString() ?? '',
          imagePaths: images,
          registeredAt: registeredAtRaw == null
              ? null
              : DateTime.tryParse(registeredAtRaw),
        ),
      );
    }

    entries.sort((a, b) {
      final aTime = a.registeredAt?.millisecondsSinceEpoch ?? 0;
      final bTime = b.registeredAt?.millisecondsSinceEpoch ?? 0;
      return bTime.compareTo(aTime);
    });

    return entries;
  }

  // ---------------------------------------------------------------------------
  // INIT / DISPOSE
  // ---------------------------------------------------------------------------

  /// Loads ML Kit + MobileFaceNet TFLite + vault from disk.
  Future<void> initialize() async {
    if (_initialized) return;

    print('[FACE] Initializing FaceService...');

    // Load TFLite interpreter from bundled asset
    _interpreter = await Interpreter.fromAsset(
      'assets/models/mobilefacenet.tflite',
    );
    print('[FACE] MobileFaceNet TFLite loaded.');

    // Load vault from disk
    await _loadVault();
    _initialized = true;
    print('[FACE] FaceService ready. Vault has ${_vault.length} people.');
  }

  Future<void> dispose() async {
    _faceDetector.close();
    _interpreter?.close();
    _initialized = false;
  }

  // ---------------------------------------------------------------------------
  // STAGE 1: DETECT + CROP FACE (ML Kit)
  // ---------------------------------------------------------------------------

  /// Detects faces in the image at [imagePath].
  /// Returns the path to a cropped face JPEG, or null if no face found.
  Future<String?> detectAndCropFace(String imagePath) async {
    print('[FACE-S1] Detecting faces in: $imagePath');

    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _faceDetector.processImage(inputImage);

    if (faces.isEmpty) {
      print('[FACE-S1] No faces detected.');
      return null;
    }

    print('[FACE-S1] Found ${faces.length} face(s). Using the largest.');

    // Pick the largest face
    final face = faces.reduce(
      (a, b) =>
          (a.boundingBox.width * a.boundingBox.height) >=
              (b.boundingBox.width * b.boundingBox.height)
          ? a
          : b,
    );

    // Read the full image and crop to the bounding box
    final bytes = await File(imagePath).readAsBytes();
    final fullImage = img.decodeImage(bytes);
    if (fullImage == null) {
      print('[FACE-S1] Failed to decode image.');
      return null;
    }

    final bbox = face.boundingBox;
    // Clamp to image bounds
    final x = bbox.left.toInt().clamp(0, fullImage.width - 1);
    final y = bbox.top.toInt().clamp(0, fullImage.height - 1);
    final w = bbox.width.toInt().clamp(1, fullImage.width - x);
    final h = bbox.height.toInt().clamp(1, fullImage.height - y);

    final cropped = img.copyCrop(fullImage, x: x, y: y, width: w, height: h);
    final croppedJpeg = img.encodeJpg(cropped, quality: 90);

    // Save to temp file
    final tempDir = await getTemporaryDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final cropPath = '${tempDir.path}/face_crop_$ts.jpg';
    await File(cropPath).writeAsBytes(croppedJpeg);

    print('[FACE-S1] Cropped face saved: $cropPath (${w}x$h)');
    return cropPath;
  }

  // ---------------------------------------------------------------------------
  // STAGE 2: GENERATE EMBEDDING (MobileFaceNet)
  // ---------------------------------------------------------------------------

  /// Converts a cropped face image into a 192-dimensional embedding vector.
  List<double> getEmbedding(String croppedFacePath) {
    final interpreter = _interpreter;
    if (interpreter == null) {
      throw StateError('MobileFaceNet not loaded.');
    }

    // Read + resize to 112x112
    final bytes = File(croppedFacePath).readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw StateError('Cannot decode cropped face.');
    final resized = img.copyResize(
      decoded,
      width: _inputSize,
      height: _inputSize,
    );

    // Normalize pixels to [-1, 1] and create input tensor [1, 112, 112, 3]
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(_inputSize, (x) {
          final pixel = resized.getPixel(x, y);
          return [
            (pixel.r.toDouble() - 127.5) / 127.5,
            (pixel.g.toDouble() - 127.5) / 127.5,
            (pixel.b.toDouble() - 127.5) / 127.5,
          ];
        }),
      ),
    );

    // Output tensor [1, 192]
    final output = List.generate(1, (_) => List.filled(_embeddingSize, 0.0));

    interpreter.run(input, output);

    final embedding = output[0];
    // L2 normalize the embedding
    final norm = sqrt(embedding.fold(0.0, (sum, v) => sum + v * v));
    if (norm > 0) {
      for (int i = 0; i < embedding.length; i++) {
        embedding[i] /= norm;
      }
    }

    print(
      '[FACE-S2] Embedding generated (${embedding.length}-d, norm=${norm.toStringAsFixed(3)})',
    );
    return embedding;
  }

  // ---------------------------------------------------------------------------
  // RECOGNITION — compare against vault
  // ---------------------------------------------------------------------------

  /// Compares [embedding] against all known faces. Returns `{name, description}` or null.
  Map<String, String>? recognizeFace(List<double> embedding) {
    if (_embeddings.isEmpty) {
      print('[FACE-REC] Vault is empty — no known faces.');
      return null;
    }

    String? bestName;
    double bestDistance = double.infinity;

    for (final entry in _embeddings.entries) {
      final name = entry.key;
      for (final known in entry.value) {
        final dist = _euclideanDistance(embedding, known);
        if (dist < bestDistance) {
          bestDistance = dist;
          bestName = name;
        }
      }
    }

    print(
      '[FACE-REC] Best match: "$bestName" (distance=${bestDistance.toStringAsFixed(4)}, threshold=$_matchThreshold)',
    );

    if (bestName != null && bestDistance < _matchThreshold) {
      final desc = (_vault[bestName]?['description'] as String?) ?? '';
      return {'name': bestName, 'description': desc};
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // REGISTRATION — save face to vault
  // ---------------------------------------------------------------------------

  /// Registers a new face with [name], [description], [embedding], and saves the [cropPath].
  Future<void> registerFace({
    required String name,
    required String description,
    required List<double> embedding,
    required String cropPath,
  }) async {
    print('[FACE-REG] Registering "$name" — desc: "$description"');

    // Save cropped face to persistent storage
    final docsDir = await getApplicationDocumentsDirectory();
    final facesDir = Directory('${docsDir.path}/faces/$name');
    if (!await facesDir.exists()) await facesDir.create(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final savedPath = '${facesDir.path}/face_$ts.jpg';
    await File(cropPath).copy(savedPath);

    // Update vault metadata
    if (_vault.containsKey(name)) {
      (_vault[name]['images'] as List).add(savedPath);
      if (description.isNotEmpty) {
        _vault[name]['description'] = description;
      }
      _vault[name]['registered_at'] = DateTime.now().toIso8601String();
    } else {
      _vault[name] = {
        'description': description,
        'images': [savedPath],
        'registered_at': DateTime.now().toIso8601String(),
      };
    }

    // Update embeddings
    _embeddings.putIfAbsent(name, () => []);
    _embeddings[name]!.add(embedding);

    // Persist to disk
    await _saveVault();

    print(
      '[FACE-REG] Saved "$name". Vault now has ${_vault.length} people, '
      '${_embeddings[name]!.length} embedding(s) for "$name".',
    );
  }

  Future<void> deleteRegisteredFace(String name) async {
    final raw = _vault[name];
    if (raw is Map<String, dynamic>) {
      final images =
          (raw['images'] as List?)
              ?.map((value) => value.toString())
              .where((value) => value.isNotEmpty)
              .toList() ??
          <String>[];

      for (final imagePath in images) {
        try {
          final file = File(imagePath);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (error) {
          print('[FACE-REG] Failed to delete image "$imagePath": $error');
        }
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    final faceDir = Directory('${docsDir.path}/faces/$name');
    if (await faceDir.exists()) {
      try {
        await faceDir.delete(recursive: true);
      } catch (error) {
        print('[FACE-REG] Failed to delete face directory for "$name": $error');
      }
    }

    _vault.remove(name);
    _embeddings.remove(name);
    await _saveVault();
    print('[FACE-REG] Deleted "$name" from the face vault.');
  }

  // ---------------------------------------------------------------------------
  // VAULT PERSISTENCE (JSON files)
  // ---------------------------------------------------------------------------

  Future<String> get _vaultDir async {
    final docsDir = await getApplicationDocumentsDirectory();
    return docsDir.path;
  }

  Future<void> _loadVault() async {
    try {
      final dir = await _vaultDir;

      // Load metadata
      final vaultFile = File('$dir/face_vault.json');
      if (await vaultFile.exists()) {
        final content = await vaultFile.readAsString();
        _vault = Map<String, dynamic>.from(jsonDecode(content));
        print('[FACE-VAULT] Loaded metadata: ${_vault.length} people.');
      } else {
        _vault = {};
        print('[FACE-VAULT] No existing vault found. Starting fresh.');
      }

      // Load embeddings
      final embFile = File('$dir/face_embeddings.json');
      if (await embFile.exists()) {
        final content = await embFile.readAsString();
        final raw = Map<String, dynamic>.from(jsonDecode(content));
        _embeddings = raw.map(
          (key, value) => MapEntry(
            key,
            (value as List)
                .map<List<double>>(
                  (e) => (e as List)
                      .map<double>((v) => (v as num).toDouble())
                      .toList(),
                )
                .toList(),
          ),
        );
        print('[FACE-VAULT] Loaded embeddings: ${_embeddings.length} people.');
      } else {
        _embeddings = {};
      }
    } catch (e) {
      print('[FACE-VAULT] Error loading vault: $e');
      _vault = {};
      _embeddings = {};
    }
  }

  Future<void> _saveVault() async {
    try {
      final dir = await _vaultDir;

      // Save metadata
      final vaultFile = File('$dir/face_vault.json');
      await vaultFile.writeAsString(jsonEncode(_vault));

      // Save embeddings
      final embFile = File('$dir/face_embeddings.json');
      await embFile.writeAsString(jsonEncode(_embeddings));

      print('[FACE-VAULT] Saved vault: ${_vault.length} people.');
    } catch (e) {
      print('[FACE-VAULT] Error saving vault: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // MATH
  // ---------------------------------------------------------------------------

  double _euclideanDistance(List<double> a, List<double> b) {
    double sum = 0;
    final len = min(a.length, b.length);
    for (int i = 0; i < len; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }
}

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum DownloadStage { model, projector }

class ModelDownloadProgress {
  final DownloadStage stage;
  final String title;
  final String filename;
  final int receivedBytes;
  final int totalBytes;
  final double stageProgress;
  final double overallProgress;

  const ModelDownloadProgress({
    required this.stage,
    required this.title,
    required this.filename,
    required this.receivedBytes,
    required this.totalBytes,
    required this.stageProgress,
    required this.overallProgress,
  });
}

class ModelManager {
  static const String modelFilename = 'LFM2-VL-450M-Q4_0.gguf';
  static const String projectorFilename = 'mmproj-LFM2-VL-450M-Q8_0.gguf';

  static const String modelUrl =
      'https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF/resolve/main/LFM2-VL-450M-Q4_0.gguf?download=true';
  static const String projectorUrl =
      'https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF/resolve/main/mmproj-LFM2-VL-450M-Q8_0.gguf?download=true';

  static const int estimatedModelBytes = 219 * 1024 * 1024;
  static const int estimatedProjectorBytes = 104 * 1024 * 1024;
  static const int estimatedTotalBytes =
      estimatedModelBytes + estimatedProjectorBytes;

  String? _modelsDir;

  Future<String> get modelsDir async {
    if (_modelsDir != null) {
      return _modelsDir!;
    }

    final documentsDir = await getApplicationDocumentsDirectory();
    final directory = Directory('${documentsDir.path}/lfm2_vl_assets');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    _modelsDir = directory.path;
    return _modelsDir!;
  }

  Future<String> get modelPath async => '${await modelsDir}/$modelFilename';

  Future<String> get projectorPath async =>
      '${await modelsDir}/$projectorFilename';

  Future<bool> areAssetsReady() async {
    return await _isUsableFile(await modelPath) &&
        await _isUsableFile(await projectorPath);
  }

  Future<void> downloadRequiredFiles({
    required void Function(ModelDownloadProgress progress) onProgress,
  }) async {
    await _downloadFile(
      stage: DownloadStage.model,
      title: 'Downloading model',
      filename: modelFilename,
      url: modelUrl,
      destinationPath: await modelPath,
      estimatedBytes: estimatedModelBytes,
      completedWeight: 0,
      stageWeight: estimatedModelBytes / estimatedTotalBytes,
      onProgress: onProgress,
    );

    await _downloadFile(
      stage: DownloadStage.projector,
      title: 'Downloading projector',
      filename: projectorFilename,
      url: projectorUrl,
      destinationPath: await projectorPath,
      estimatedBytes: estimatedProjectorBytes,
      completedWeight: estimatedModelBytes / estimatedTotalBytes,
      stageWeight: estimatedProjectorBytes / estimatedTotalBytes,
      onProgress: onProgress,
    );
  }

  Future<void> deleteAssets() async {
    final directory = Directory(await modelsDir);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
    _modelsDir = null;
  }

  Future<void> _downloadFile({
    required DownloadStage stage,
    required String title,
    required String filename,
    required String url,
    required String destinationPath,
    required int estimatedBytes,
    required double completedWeight,
    required double stageWeight,
    required void Function(ModelDownloadProgress progress) onProgress,
  }) async {
    final destinationFile = File(destinationPath);
    if (await _isUsableFile(destinationPath)) {
      onProgress(
        ModelDownloadProgress(
          stage: stage,
          title: title,
          filename: filename,
          receivedBytes: estimatedBytes,
          totalBytes: estimatedBytes,
          stageProgress: 1,
          overallProgress: completedWeight + stageWeight,
        ),
      );
      return;
    }

    if (await destinationFile.exists()) {
      await destinationFile.delete();
    }

    final partialFile = File('$destinationPath.part');
    if (await partialFile.exists()) {
      await partialFile.delete();
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode} for $filename',
        );
      }

      final totalBytes = response.contentLength ?? estimatedBytes;
      var receivedBytes = 0;
      final sink = partialFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        final stageProgress = totalBytes > 0
            ? receivedBytes / totalBytes
            : 0.0;
        onProgress(
          ModelDownloadProgress(
            stage: stage,
            title: title,
            filename: filename,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            stageProgress: stageProgress.clamp(0.0, 1.0).toDouble(),
            overallProgress: (completedWeight + (stageWeight * stageProgress))
                .clamp(0.0, 1.0)
                .toDouble(),
          ),
        );
      }

      await sink.flush();
      await sink.close();

      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }
      await partialFile.rename(destinationPath);

      onProgress(
        ModelDownloadProgress(
          stage: stage,
          title: title,
          filename: filename,
          receivedBytes: totalBytes,
          totalBytes: totalBytes,
          stageProgress: 1,
          overallProgress:
              (completedWeight + stageWeight).clamp(0.0, 1.0).toDouble(),
        ),
      );
    } catch (_) {
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<bool> _isUsableFile(String path) async {
    final file = File(path);
    return file.existsSync() && await file.length() > 0;
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

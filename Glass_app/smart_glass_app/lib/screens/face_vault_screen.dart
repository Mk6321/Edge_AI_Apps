import 'dart:io';

import 'package:flutter/material.dart';

import '../services/face_service.dart';

class FaceVaultScreen extends StatefulWidget {
  const FaceVaultScreen({super.key, required this.faceService});

  final FaceService faceService;

  @override
  State<FaceVaultScreen> createState() => _FaceVaultScreenState();
}

class _FaceVaultScreenState extends State<FaceVaultScreen> {
  late List<FaceVaultEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = widget.faceService.getRegisteredFaces();
  }

  Future<void> _deleteEntry(FaceVaultEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          title: const Text(
            'Delete Registered Face',
            style: TextStyle(color: Colors.white),
          ),
          content: Text(
            'Remove ${entry.name} and all saved face photos from the vault?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    await widget.faceService.deleteRegisteredFace(entry.name);
    if (!mounted) {
      return;
    }

    setState(() {
      _entries = widget.faceService.getRegisteredFaces();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: const Text(
          'Face Vault',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: _entries.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No registered faces yet.',
                  style: TextStyle(color: Colors.grey, fontSize: 18),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return _FaceVaultCard(
                  entry: entry,
                  onDelete: () => _deleteEntry(entry),
                );
              },
            ),
    );
  }
}

class _FaceVaultCard extends StatelessWidget {
  const _FaceVaultCard({required this.entry, required this.onDelete});

  final FaceVaultEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                onPressed: onDelete,
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
              ),
            ],
          ),
          if (entry.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              entry.description,
              style: const TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Saved photos: ${entry.imagePaths.length}',
            style: const TextStyle(color: Colors.blueGrey, fontSize: 13),
          ),
          if (entry.registeredAt != null) ...[
            const SizedBox(height: 4),
            Text(
              'Updated: ${entry.registeredAt!.toLocal()}',
              style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: entry.imagePaths.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                return _FaceVaultImage(path: entry.imagePaths[index]);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FaceVaultImage extends StatelessWidget {
  const _FaceVaultImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final file = File(path);

    return GestureDetector(
      onTap: () {
        showDialog<void>(
          context: context,
          builder: (context) {
            return Dialog(
              backgroundColor: const Color(0xFF161B22),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: file.existsSync()
                    ? InteractiveViewer(child: Image.file(file))
                    : const Text(
                        'Image file not found.',
                        style: TextStyle(color: Colors.white),
                      ),
              ),
            );
          },
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 96,
          color: const Color(0xFF0D1117),
          child: file.existsSync()
              ? Image.file(file, fit: BoxFit.cover)
              : const Center(
                  child: Icon(Icons.broken_image, color: Colors.grey),
                ),
        ),
      ),
    );
  }
}

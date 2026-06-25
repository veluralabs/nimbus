import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shimmer/shimmer.dart';

import '../data/app_db.dart';
import '../models/media_asset.dart';
import '../services/gemini_edit_service.dart';
import '../services/media_service.dart';
import '../theme.dart';
import 'widgets/glass.dart';

/// AI photo editor (Gemini image model on Vertex AI). Type or tap a preset; the
/// edited result is saved as a NEW asset so the original is always kept.
/// Hold the preview to compare against the original.
class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.asset, this.onSaved});
  final MediaAsset asset;
  final VoidCallback? onSaved;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  final _gemini = GeminiEditService();
  final _media = MediaService();
  final _prompt = TextEditingController();
  final _promptFocus = FocusNode();

  File? _sourceFile;
  Uint8List? _result;
  bool _busy = false;
  bool _showOriginal = false;
  String? _error;

  static const _presets = [
    ('Enhance', Icons.auto_awesome, 'Enhance quality, sharpness and lighting'),
    ('Golden hour', Icons.wb_twilight, 'Make it warm golden-hour light'),
    ('Remove BG', Icons.layers_clear, 'Remove the background, keep the subject'),
    ('Restore', Icons.healing, 'Restore and de-noise this old photo'),
    ('B&W', Icons.filter_b_and_w, 'Convert to elegant black and white'),
    ('Vivid', Icons.palette, 'Make the colors vivid and punchy'),
  ];

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void dispose() {
    _gemini.dispose();
    _prompt.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final a = widget.asset;
    File? f;
    if (a.isFileAsset && a.localPath != null) {
      f = File(a.localPath!);
    } else {
      final e = await _media.entity(a.id);
      f = await e?.file;
    }
    if (mounted) setState(() => _sourceFile = f);
  }

  Future<void> _apply(String prompt) async {
    if (_sourceFile == null || prompt.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final edited = await _gemini.edit(_sourceFile!, prompt.trim());
      if (mounted) setState(() => _result = edited);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not edit — $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_result == null) return;
    final dir = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'edited'));
    await dir.create(recursive: true);
    final base = p.basenameWithoutExtension(widget.asset.name);
    final tag = (widget.asset.id.hashCode ^ _prompt.text.hashCode)
        .toUnsigned(32)
        .toRadixString(16);
    final path = p.join(dir.path, 'edited_${base}_$tag.jpg');
    await File(path).writeAsBytes(_result!);

    final edited = MediaAsset(
      id: 'file:$path',
      name: 'Edited · ${widget.asset.name}',
      kind: MediaKind.image,
      size: _result!.length,
      createdAt: DateTime.now(), // show at the top (Today) so it's easy to find
      localPath: path,
    );
    await AppDb.instance.upsertNewAssets([edited]);
    widget.onSaved?.call(); // refresh the gallery so the edit appears now
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Saved — added to Photos (Today). Original kept.'),
      ));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('AI Edit'),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  gradient: NimbusTheme.brandGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Gemini 3.1',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          actions: [
            if (_result != null && !_busy)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 14)),
                  onPressed: _save,
                  icon: const Icon(Icons.save_alt_rounded, size: 18),
                  label: const Text('Save'),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(child: _preview()),
            _controls(),
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    if (_busy && _sourceFile != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          Shimmer.fromColors(
            baseColor: Colors.white10,
            highlightColor: Colors.white24,
            child: Image.file(_sourceFile!, fit: BoxFit.contain),
          ),
          Glass(
            radius: 20,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Text('Editing with Gemini…'),
              ],
            ),
          ),
        ],
      );
    }

    final showResult = _result != null && !_showOriginal;
    Widget image;
    if (showResult) {
      image = Image.memory(_result!, fit: BoxFit.contain);
    } else if (_sourceFile != null) {
      image = Image.file(_sourceFile!, fit: BoxFit.contain);
    } else {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            // No result yet: tap the image to start writing a prompt.
            // With a result: hold to compare against the original.
            onTap: _result == null
                ? () => _promptFocus.requestFocus()
                : null,
            onTapDown: _result == null
                ? null
                : (_) => setState(() => _showOriginal = true),
            onTapUp: _result == null
                ? null
                : (_) => setState(() => _showOriginal = false),
            onTapCancel: _result == null
                ? null
                : () => setState(() => _showOriginal = false),
            child: InteractiveViewer(child: Center(child: image)),
          ),
        ),
        if (_result != null)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Glass(
                radius: 20,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                child: Text(
                  _showOriginal ? 'Original' : 'Edited · hold to compare',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _controls() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 26,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12)),
                ),
              SizedBox(
                height: 38,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _presets.length,
                  separatorBuilder: (_, i) => const SizedBox(width: 8),
                  itemBuilder: (ctx, i) {
                    final (label, icon, prompt) = _presets[i];
                    return ActionChip(
                      avatar: Icon(icon, size: 16),
                      label: Text(label),
                      onPressed: _busy
                          ? null
                          : () {
                              _prompt.text = prompt;
                              _apply(prompt);
                            },
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _prompt,
                      focusNode: _promptFocus,
                      enabled: !_busy,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        hintText: 'Describe an edit…',
                        prefixIcon: Icon(Icons.auto_fix_high_rounded),
                      ),
                      onSubmitted: _apply,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _busy ? null : () => _apply(_prompt.text),
                      child: const Icon(Icons.arrow_upward_rounded),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

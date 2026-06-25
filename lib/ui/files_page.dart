import 'package:flutter/material.dart';

import '../data/app_db.dart';
import '../models/media_asset.dart';
import '../theme.dart';
import '../util.dart';
import 'asset_grid_screen.dart';
import 'cloud_browser.dart';
import 'widgets/glass.dart';
import 'widgets/shimmers.dart';

/// "Files" tab — a My-Files-style view with a folder per media kind
/// (Photos, Videos, Documents, Audio), each showing item count + size.
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.uid});
  final String uid;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final _db = AppDb.instance;
  List<({MediaKind kind, int count, int bytes})> _summary = [];
  bool _loading = true;

  static const _meta = {
    MediaKind.image: ('Photos', Icons.photo_rounded, Color(0xFF7C5CFF)),
    MediaKind.video: ('Videos', Icons.movie_rounded, Color(0xFF00B4D8)),
    MediaKind.document: ('Documents', Icons.description_rounded, Color(0xFFE84393)),
    MediaKind.audio: ('Audio', Icons.audiotrack_rounded, Color(0xFFFFA726)),
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await _db.kindSummary();
    if (mounted) {
      setState(() {
        _summary = s;
        _loading = false;
      });
    }
  }

  ({MediaKind kind, int count, int bytes}) _for(MediaKind k) => _summary
      .firstWhere((e) => e.kind == k, orElse: () => (kind: k, count: 0, bytes: 0));

  Future<void> _open(MediaKind k, String title) async {
    final assets = await _db.assetsByKind(k);
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AssetGridScreen(title: title, assets: assets),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Files')),
      body: _loading
          ? const ShimmerList()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                children: [
                  _cloudCard(),
                  const SizedBox(height: 12),
                  for (final k in MediaKind.values) _folderTile(k),
                ],
              ),
            ),
    );
  }

  Widget _cloudCard() {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => CloudBrowserScreen(uid: widget.uid)),
      ),
      child: Glass(
        radius: 22,
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: NimbusTheme.brandGradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.cloud_rounded, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cloud storage',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('Browse what\'s in your bucket — live',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }

  Widget _folderTile(MediaKind k) {
    final (name, icon, color) = _meta[k]!;
    final info = _for(k);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: info.count == 0 ? null : () => _open(k, name),
        child: Glass(
          radius: 22,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      '${info.count} items • ${humanSize(info.bytes)}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';

import '../data/app_db.dart';
import '../models/media_asset.dart';
import '../services/gcs_client.dart';
import '../services/media_service.dart';
import '../labels.dart';
import '../util.dart';
import 'edit_screen.dart';
import 'search_screen.dart';
import 'video_player_view.dart';
import 'widgets/sheets.dart';
import 'widgets/shimmers.dart';

final _media = MediaService();

/// Full-screen, swipeable photo viewer. Opens when a thumbnail is tapped.
/// Shows the full-resolution image plus its backup status and category labels.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.assets,
    required this.initialIndex,
    this.onDeleted,
    this.onChanged,
  });
  final List<MediaAsset> assets;
  final int initialIndex;

  /// Called with the asset id after it's deleted, so the opening screen can
  /// drop it from its list immediately.
  final void Function(String id)? onDeleted;

  /// Called after a change that adds assets (e.g. an AI edit) so the opening
  /// screen can refresh.
  final VoidCallback? onChanged;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: _index);
    // Immersive full-screen: hide status + nav bars while viewing.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    _controller.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  final _db = AppDb.instance;

  Future<File?> _resolveFile(MediaAsset a) async {
    if (a.isFileAsset && a.localPath != null) return File(a.localPath!);
    final e = await _media.entity(a.id);
    return e?.file;
  }

  Future<void> _share() async {
    final a = widget.assets[_index];
    final file = await _resolveFile(a);
    if (file == null || !await file.exists()) {
      _toast('Original not on device (freed to save space)');
      return;
    }
    await Share.shareXFiles([XFile(file.path)]);
  }

  void _edit() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditScreen(
          asset: widget.assets[_index],
          onSaved: widget.onChanged,
        ),
      ),
    );
  }

  String _fmtDate(DateTime d) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    final mm = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, ${d.year} · $h:$mm $ampm';
  }

  void _info() {
    final a = widget.assets[_index];
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: FutureBuilder<AssetMeta?>(
          future: a.isFileAsset ? Future.value(null) : _media.metadata(a.id),
          builder: (ctx, snap) {
            final meta = snap.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _InfoRow('Name', a.name),
                _InfoRow('Type', a.kind.name),
                _InfoRow('Size', a.size > 0 ? humanSize(a.size) : '—'),
                _InfoRow('Taken', _fmtDate(meta?.date ?? a.createdAt)),
                if (snap.connectionState != ConnectionState.done)
                  const _InfoRow('Location', 'Reading…')
                else if (meta?.place != null)
                  _InfoRow('Location', meta!.place!)
                else if (meta?.hasLocation ?? false)
                  _InfoRow('Location',
                      '${meta!.lat!.toStringAsFixed(4)}, ${meta.lng!.toStringAsFixed(4)}')
                else
                  const _InfoRow('Location', 'No location in this photo'),
                _InfoRow('Backup', switch (a.status) {
                  SyncStatus.uploaded => 'Backed up',
                  SyncStatus.deletedLocal => 'Backed up · freed locally',
                  SyncStatus.uploading => 'Uploading…',
                  SyncStatus.failed => 'Failed',
                  SyncStatus.pending => 'Not backed up',
                }),
                if (a.labels.isNotEmpty)
                  _InfoRow('Categories', a.labels.join(', ')),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final a = widget.assets[_index];
    final ok = await confirmSheet(
      context,
      title: 'Delete this item?',
      message: a.isSafeInCloud
          ? 'Removes it from this device and the gallery. Your cloud backup is kept, so it is not lost.'
          : 'This is NOT backed up. Deleting removes it permanently — it cannot be recovered.',
      confirmLabel: 'Delete',
      icon: Icons.delete_outline_rounded,
      danger: true,
    );
    if (!ok) return;
    // Try to remove the device file — but don't let a failure (e.g. the file
    // was already deleted) block removing the stale index entry.
    try {
      if (a.isFileAsset && a.localPath != null) {
        await File(a.localPath!).delete();
      } else {
        await _media.deleteAssets([a.id]);
      }
    } catch (_) {/* file may already be gone — still clear the entry */}
    // Always remove from the index so it disappears from the gallery.
    if (widget.onDeleted != null) {
      widget.onDeleted!(a.id);
    } else {
      await _db.removeAssets([a.id]);
    }
    if (mounted) Navigator.pop(context);
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.assets[_index];
    final tags = cleanLabels(asset.labels);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          asset.name,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
        ),
        actions: [_StatusChip(status: asset.status)],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.assets.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (ctx, i) => _FullImage(asset: widget.assets[i]),
      ),
      bottomNavigationBar: Container(
        color: Colors.black,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      const Icon(Icons.local_offer_outlined,
                          size: 14, color: Colors.white54),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final label in tags)
                              GestureDetector(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        SearchScreen(initialQuery: label),
                                  ),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                        color: Colors.white24, width: 0.5),
                                  ),
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionButton(icon: Icons.share_rounded, label: 'Share', onTap: _share),
                  if (asset.kind == MediaKind.image)
                    _ActionButton(
                        icon: Icons.auto_fix_high_rounded,
                        label: 'AI Edit',
                        onTap: _edit),
                  _ActionButton(icon: Icons.info_outline_rounded, label: 'Info', onTap: _info),
                  _ActionButton(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      onTap: _delete),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// Renders one asset full-screen, branching by kind and availability:
/// - image: full-res locally, or cached thumb + "Download original" if freed
/// - video: large frame + play badge (in-app playback is a follow-up)
/// - audio/document: typed icon + filename
class _FullImage extends StatefulWidget {
  const _FullImage({required this.asset});
  final MediaAsset asset;

  @override
  State<_FullImage> createState() => _FullImageState();
}

class _FullImageState extends State<_FullImage> {
  Uint8List? _downloaded;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    // Freed-to-cloud image: auto-download the original on open. It's held in
    // memory only and discarded when the viewer closes — so it re-offloads
    // automatically, never touching device storage again.
    final a = widget.asset;
    if (a.status == SyncStatus.deletedLocal && a.remotePath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _downloadOriginal());
    }
  }

  Future<Uint8List?> _localImage() async {
    final a = widget.asset;
    if (a.isFileAsset && a.localPath != null) {
      final f = File(a.localPath!);
      return await f.exists() ? f.readAsBytes() : null;
    }
    final entity = await _media.entity(a.id);
    return await entity?.originBytes ??
        await _media.thumbnail(a.id, px: 1080);
  }

  Future<void> _downloadOriginal() async {
    final remote = widget.asset.remotePath;
    if (remote == null) return;
    setState(() => _downloading = true);
    final gcs = GcsClient();
    try {
      await gcs.init();
      final bytes = await gcs.download(remote);
      if (mounted) setState(() => _downloaded = Uint8List.fromList(bytes));
    } catch (_) {
      // leave cached thumb showing
    } finally {
      gcs.dispose();
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;

    // Non-visual kinds.
    if (a.kind == MediaKind.audio || a.kind == MediaKind.document) {
      return _Centered(
        icon: a.kind == MediaKind.audio
            ? Icons.audiotrack_rounded
            : Icons.description_rounded,
        text: a.name,
      );
    }

    // Video: in-app playback.
    if (a.kind == MediaKind.video) {
      return VideoPlayerView(asset: a);
    }

    // Image: downloaded original wins, else local, else cached thumb.
    if (_downloaded != null) return _zoom(_downloaded!);

    // Freed image: show the cached thumb under a shimmer while the full-res
    // original streams down from the cloud (auto-started in initState).
    if (a.status == SyncStatus.deletedLocal && a.thumbPath != null) {
      return Stack(
        alignment: Alignment.center,
        children: [
          Shimmer.fromColors(
            baseColor: Colors.white10,
            highlightColor: Colors.white24,
            enabled: _downloading,
            child: _zoom(File(a.thumbPath!).readAsBytesSync()),
          ),
          if (_downloading)
            const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: Colors.white)),
                SizedBox(height: 12),
                Text('Loading full photo from cloud…',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            )
          else
            // Download failed — let the user retry.
            FilledButton.icon(
              onPressed: _downloadOriginal,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Tap to load original'),
            ),
        ],
      );
    }

    return FutureBuilder<Uint8List?>(
      future: _localImage(),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(40),
            child: ShimmerBox(height: 320, radius: 18),
          );
        }
        if (snap.data == null) {
          return const _Centered(
              icon: Icons.broken_image_outlined, text: 'Unavailable');
        }
        return _zoom(snap.data!);
      },
    );
  }

  Widget _zoom(Uint8List bytes) => InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Center(
          child: Hero(
            tag: 'photo_${widget.asset.id}',
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
      );
}

class _Centered extends StatelessWidget {
  const _Centered({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Colors.white54),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    late IconData icon;
    late String text;
    switch (status) {
      case SyncStatus.uploaded:
      case SyncStatus.deletedLocal:
        icon = Icons.cloud_done_rounded;
        text = 'Backed up';
        break;
      case SyncStatus.uploading:
        icon = Icons.cloud_sync_rounded;
        text = 'Uploading';
        break;
      case SyncStatus.failed:
        icon = Icons.error_outline_rounded;
        text = 'Failed';
        break;
      case SyncStatus.pending:
        icon = Icons.cloud_queue_rounded;
        text = 'Not backed up';
        break;
    }
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(children: [
        Icon(icon, size: 18, color: Colors.white70),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ]),
    );
  }
}

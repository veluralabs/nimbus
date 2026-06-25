import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../models/media_asset.dart';
import '../../services/media_service.dart';

final _media = MediaService();

/// Square tile for any asset kind:
/// - image/video: thumbnail (cached thumb if the original was freed)
/// - audio/document: a typed icon tile
/// Tappable when [onTap] is provided (opens the full-screen viewer).
class AssetThumb extends StatelessWidget {
  const AssetThumb({
    super.key,
    required this.asset,
    this.onTap,
    this.onLongPress,
    this.heroTag,
    this.selected = false,
  });
  final MediaAsset asset;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? heroTag;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget preview = ClipRRect(
      borderRadius: BorderRadius.circular(selected ? 14 : 10),
      child: _preview(scheme),
    );
    if (heroTag != null) {
      preview = Hero(tag: heroTag!, child: preview);
    }
    return RepaintBoundary(
      child: GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.all(selected ? 8 : 0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            preview,
            if (selected)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            Positioned(
              left: 4,
              top: 4,
              child: AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: CircleAvatar(
                  radius: 11,
                  backgroundColor: scheme.primary,
                  child: const Icon(Icons.check, size: 14, color: Colors.white),
                ),
              ),
            ),
          if (asset.kind == MediaKind.video)
            Center(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(6),
                child: const Icon(Icons.play_arrow_rounded,
                    size: 22, color: Colors.white),
              ),
            ),
            if (asset.accessible || asset.thumbPath != null)
              Positioned(
                right: 4,
                top: 4,
                child: _StatusBadge(status: asset.status),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _preview(ColorScheme scheme) {
    // Non-visual kinds: typed icon tile.
    if (asset.kind == MediaKind.audio || asset.kind == MediaKind.document) {
      return _IconTile(asset: asset, scheme: scheme);
    }
    // Cloned-app images (/emulated/999/) Android won't let us read — show a
    // clear label instead of a generic broken-image icon. Cached thumb (if the
    // item was readable earlier) still takes priority below.
    if (!asset.accessible && asset.thumbPath == null) {
      return _ClonedTile(scheme: scheme);
    }
    // Original was freed to save space -> show the cached thumbnail.
    if (asset.thumbPath != null) {
      return Image.file(File(asset.thumbPath!),
          fit: BoxFit.cover, gaplessPlayback: true,
          errorBuilder: (c, e, s) => Container(color: scheme.surfaceContainerHighest));
    }
    // Instant render if the thumbnail is already cached (avoids a FutureBuilder
    // rebuild flash and a redundant decode on every scroll/rebuild).
    final cached = MediaService.cachedThumb(asset.id, px: 220);
    if (cached != null) {
      return Image.memory(cached,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (c, e, s) => _failed(scheme));
    }
    return FutureBuilder(
      future: _media.thumbnail(asset.id, px: 220),
      builder: (ctx, snap) {
        // Still loading -> shimmer.
        if (snap.connectionState != ConnectionState.done) {
          return Shimmer.fromColors(
            baseColor: scheme.surfaceContainerHighest,
            highlightColor: scheme.surfaceContainerHigh,
            child: Container(color: scheme.surfaceContainerHighest),
          );
        }
        if (snap.data == null) return _failed(scheme);
        return Image.memory(snap.data!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (c, e, s) => _failed(scheme));
      },
    );
  }

  Widget _failed(ColorScheme scheme) => Container(
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.image_not_supported_outlined,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5), size: 22),
      );
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.asset, required this.scheme});
  final MediaAsset asset;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final isAudio = asset.kind == MediaKind.audio;
    final ext = asset.name.contains('.')
        ? asset.name.split('.').last.toUpperCase()
        : (isAudio ? 'AUDIO' : 'FILE');
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isAudio ? Icons.audiotrack_rounded : Icons.description_rounded,
            size: 28,
            color: scheme.primary,
          ),
          const SizedBox(height: 6),
          Text(ext,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Placeholder for cloned-app items (App-Clone / Parallel-App WhatsApp etc.)
/// stored under /storage/emulated/999/, which Android blocks us from reading.
class _ClonedTile extends StatelessWidget {
  const _ClonedTile({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.copy_all_rounded,
              size: 24, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
          const SizedBox(height: 6),
          Text('Cloned app\ncan’t access',
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                  fontSize: 9.5,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    late IconData icon;
    late Color color;
    switch (status) {
      case SyncStatus.uploaded:
        icon = Icons.cloud_done_rounded;
        color = Colors.greenAccent.shade400;
        break;
      case SyncStatus.deletedLocal:
        icon = Icons.cloud_done_rounded;
        color = Colors.lightGreenAccent.shade400;
        break;
      case SyncStatus.uploading:
        icon = Icons.cloud_sync_rounded;
        color = Colors.lightBlueAccent;
        break;
      case SyncStatus.failed:
        icon = Icons.error_rounded;
        color = Colors.redAccent;
        break;
      case SyncStatus.pending:
        icon = Icons.cloud_queue_rounded;
        color = Colors.white70;
        break;
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.all(2),
      child: Icon(icon, size: 15, color: color),
    );
  }
}

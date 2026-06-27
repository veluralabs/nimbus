import 'dart:io';
import 'dart:typed_data';

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
    // Original was freed to save space -> show the cached thumbnail.
    if (asset.thumbPath != null) {
      return Image.file(File(asset.thumbPath!),
          fit: BoxFit.cover, gaplessPlayback: true,
          errorBuilder: (c, e, s) => Container(color: scheme.surfaceContainerHighest));
    }
    // Self-healing loader: on-device thumbnail first (fast, no network); if that
    // keeps failing, fall back to downloading the already-uploaded object from
    // the cloud and downscaling it (reliable). Caches the result either way.
    return _ThumbImage(asset: asset, scheme: scheme);
  }
}

/// Loads a grid thumbnail: tries the on-device thumbnailer (with a couple of
/// cold-start retries), then — for items already in the cloud — downloads the
/// uploaded object and downscales it. The latter never fails for backed-up
/// items, so stubborn tiles finally resolve instead of staying broken.
class _ThumbImage extends StatefulWidget {
  const _ThumbImage({required this.asset, required this.scheme});
  final MediaAsset asset;
  final ColorScheme scheme;

  @override
  State<_ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends State<_ThumbImage> {
  Uint8List? _bytes;
  bool _loading = true;
  int _attempt = 0;
  static const _maxLocalAttempts = 2; // then fall back to cloud

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _ThumbImage old) {
    super.didUpdateWidget(old);
    // Grid recycles State across assets — reload if this slot now shows another.
    if (old.asset.id != widget.asset.id) {
      _attempt = 0;
      _start();
    }
  }

  void _start() {
    final cached = MediaService.cachedThumb(widget.asset.id, px: 220);
    if (cached != null) {
      _bytes = cached;
      _loading = false;
    } else {
      _bytes = null;
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    Uint8List? b;
    try {
      b = await _media.thumbnail(widget.asset.id, px: 220);
    } catch (_) {/* treated as failure below */}
    if (!mounted) return;
    if (b != null) {
      setState(() {
        _bytes = b;
        _loading = false;
      });
      return;
    }
    // A couple of quick local retries to ride out cold-start contention.
    if (_attempt < _maxLocalAttempts) {
      _attempt++;
      await Future.delayed(Duration(milliseconds: 300 * _attempt));
      if (mounted) _load();
      return;
    }
    // Reliable fallback: pull the already-uploaded object from the cloud.
    if (widget.asset.remotePath != null) {
      Uint8List? cloud;
      try {
        cloud = await _media.cloudThumbnail(widget.asset);
      } catch (_) {/* fall through to placeholder */}
      if (!mounted) return;
      if (cloud != null) {
        setState(() {
          _bytes = cloud;
          _loading = false;
        });
        return;
      }
    }
    setState(() => _loading = false); // genuinely failed -> placeholder
  }

  /// A returned-but-undecodable image is also a failure: drop it and retry.
  void _onDecodeError() {
    if (!mounted || _attempt >= _maxLocalAttempts) return;
    _attempt++;
    _bytes = null;
    _loading = true;
    Future.delayed(Duration(milliseconds: 300 * _attempt), () {
      if (mounted) _load();
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    if (_bytes != null) {
      return Image.memory(_bytes!,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (c, e, s) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _onDecodeError());
            return _failed(scheme);
          });
    }
    if (_loading) {
      return Shimmer.fromColors(
        baseColor: scheme.surfaceContainerHighest,
        highlightColor: scheme.surfaceContainerHigh,
        child: Container(color: scheme.surfaceContainerHighest),
      );
    }
    return _failed(scheme);
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

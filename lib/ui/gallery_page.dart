import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../config.dart';
import '../data/app_db.dart';
import '../models/media_asset.dart';
import '../services/media_service.dart';
import '../services/sync_controller.dart';
import '../theme.dart';
import 'photo_viewer.dart';
import 'search_screen.dart';
import 'widgets/asset_thumb.dart';
import 'widgets/glass.dart';
import 'widgets/pinch_detector.dart';
import 'widgets/sheets.dart';

final _media = MediaService();

Future<File?> _resolve(MediaAsset a) async {
  if (a.isFileAsset && a.localPath != null) return File(a.localPath!);
  final e = await _media.entity(a.id);
  return e?.file;
}

class GalleryPage extends StatelessWidget {
  const GalleryPage({super.key, required this.sync});
  final SyncController sync;

  /// Renders the PRE-COMPUTED timeline sections (grouping happens once in the
  /// controller, not on every rebuild). Photos & videos only.
  List<Widget> _buildTimeline(BuildContext context) {
    final visible = sync.visibleAssets;
    final slivers = <Widget>[];
    for (final section in sync.sections) {
      slivers.add(SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(section.label,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      ));
      slivers.add(SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: sync.gridExtent,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, j) {
              final globalIndex = section.startIndex + j;
              final a = section.assets[j];
              return AssetThumb(
                asset: a,
                heroTag: 'photo_${a.id}',
                selected: sync.selected.contains(a.id),
                onLongPress: () => sync.toggleSelect(a.id),
                onTap: () {
                  if (sync.selecting) {
                    sync.toggleSelect(a.id);
                  } else {
                    Navigator.push(
                      ctx,
                      MaterialPageRoute(
                        builder: (_) => PhotoViewer(
                          assets: visible,
                          initialIndex: globalIndex,
                          onDeleted: (id) => sync.removeFromView([id]),
                          onChanged: sync.refreshFromDb,
                        ),
                      ),
                    );
                  }
                },
              );
            },
            childCount: section.assets.length,
          ),
        ),
      ));
    }
    return slivers;
  }

  Future<void> _shareSelected(BuildContext context) async {
    final files = <XFile>[];
    for (final a in sync.selectedAssets) {
      final f = await _resolve(a);
      if (f != null && await f.exists()) files.add(XFile(f.path));
    }
    sync.clearSelection();
    if (files.isNotEmpty) await Share.shareXFiles(files);
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final items = sync.selectedAssets;
    final ok = await confirmSheet(
      context,
      title: 'Delete ${items.length} items?',
      message:
          'Backed-up items are removed from the device (kept in cloud as thumbnails). '
          'Not-yet-backed-up items are deleted permanently.',
      confirmLabel: 'Delete',
      icon: Icons.delete_outline_rounded,
      danger: true,
    );
    if (!ok) return;
    for (final a in items) {
      try {
        a.thumbPath ??= await _media.cacheThumb(a);
        if (a.isFileAsset && a.localPath != null) {
          await File(a.localPath!).delete();
        } else {
          await _media.deleteAssets([a.id]);
        }
        if (a.isSafeInCloud) {
          a.status = SyncStatus.deletedLocal;
          await AppDb.instance.updateAsset(a);
        }
      } catch (_) {/* skip */}
    }
    await sync.removeFromView(items.map((a) => a.id).toList());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        return PinchDetector(
          onStart: sync.startZoom,
          onScale: sync.zoom,
          child: RefreshIndicator(
          onRefresh: sync.scan,
          child: CustomScrollView(
          slivers: [
            if (sync.selecting)
              SliverAppBar(
                floating: true,
                pinned: true,
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: sync.clearSelection,
                ),
                title: Text('${sync.selected.length} selected'),
                actions: [
                  IconButton(
                    tooltip: 'Share',
                    icon: const Icon(Icons.share_rounded),
                    onPressed: () => _shareSelected(context),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _deleteSelected(context),
                  ),
                ],
              )
            else
              SliverAppBar(
                floating: true,
                title: const Text(Config.appName),
                actions: [
                  IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.search),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SearchScreen()),
                    ),
                  ),
                  if (sync.syncing)
                    TextButton.icon(
                      onPressed: sync.stop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stop'),
                    )
                  else
                    IconButton(
                      tooltip: 'Back up now',
                      onPressed: sync.scanning ? null : sync.syncNow,
                      icon: const Icon(Icons.backup_rounded),
                    ),
                ],
              ),
            SliverToBoxAdapter(child: _ProgressCard(sync: sync)),
            if (sync.visibleAssets.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    sync.scanning ? 'Scanning your library…' : 'No photos found yet',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              )
            else
              ..._buildTimeline(context),
            const SliverToBoxAdapter(child: SizedBox(height: 110)),
          ],
          ),
        ),
        );
      },
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.sync});
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final allDone = sync.total > 0 && sync.backedUp == sync.total && !sync.syncing;

    // While the background service runs, mirror its live counts; otherwise show
    // the static backed-up summary from the index.
    final bool serviceRunning = sync.syncing && sync.bgTotal > 0;
    final double ratio = serviceRunning
        ? sync.bgDone / sync.bgTotal
        : (sync.total == 0 ? 0.0 : sync.backedUp / sync.total);

    final String title = sync.reconciling
        ? 'Checking your cloud backup…'
        : allDone
            ? 'Everything backed up'
            : sync.syncing
                ? (sync.bgPhase == 'analyze'
                    ? 'Organizing your library…'
                    : 'Backing up…')
                : '${sync.pending} to back up';

    final String detail = serviceRunning
        ? '${sync.bgDone} / ${sync.bgTotal} '
            '${sync.bgPhase == 'analyze' ? 'analyzed' : 'uploaded'} • running in background'
        : '${sync.backedUp} / ${sync.total} backed up'
            '${sync.failed > 0 ? ' • ${sync.failed} failed' : ''}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Glass(
        radius: 24,
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: NimbusTheme.brandGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    allDone
                        ? Icons.verified_rounded
                        : sync.bgPhase == 'analyze'
                            ? Icons.auto_awesome_rounded
                            : Icons.cloud_upload_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: sync.scanning || (sync.syncing && sync.bgTotal == 0)
                    ? null
                    : ratio,
                minHeight: 8,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
              ),
            ),
            const SizedBox(height: 10),
            Text(detail,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

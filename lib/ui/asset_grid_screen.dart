import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../models/media_asset.dart';
import '../services/media_service.dart';
import 'photo_viewer.dart';
import 'widgets/asset_thumb.dart';
import 'widgets/glass.dart';

final _media = MediaService();

/// Opens a document/audio file with the system's default app.
Future<void> openExternally(MediaAsset a) async {
  String? path = a.localPath;
  if (path == null && !a.isFileAsset) {
    final e = await _media.entity(a.id);
    path = (await e?.file)?.path;
  }
  if (path != null) await OpenFilex.open(path);
}

/// Generic full-screen grid used for a person's photos, a category, or a Files
/// folder. Aurora + glass styled to match the app; videos show a play badge.
class AssetGridScreen extends StatelessWidget {
  const AssetGridScreen({super.key, required this.title, required this.assets});
  final String title;
  final List<MediaAsset> assets;

  @override
  Widget build(BuildContext context) {
    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(title),
          // Frosted header bar.
          flexibleSpace: const Glass(radius: 0, blur: 18, border: false, child: SizedBox.expand()),
        ),
        body: assets.isEmpty
            ? const Center(child: Text('Nothing here yet'))
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 120,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: assets.length,
                itemBuilder: (ctx, i) {
                  final a = assets[i];
                  final isDoc = a.kind == MediaKind.document ||
                      a.kind == MediaKind.audio;
                  return AssetThumb(
                    asset: a,
                    heroTag: 'grid_${a.id}',
                    onTap: () {
                      if (isDoc) {
                        openExternally(a); // open with default app
                      } else {
                        Navigator.push(
                          ctx,
                          MaterialPageRoute(
                            builder: (_) =>
                                PhotoViewer(assets: assets, initialIndex: i),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
      ),
    );
  }
}

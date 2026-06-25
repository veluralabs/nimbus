import 'package:flutter/material.dart';

import '../data/app_db.dart';
import '../labels.dart';
import '../models/media_asset.dart';
import '../services/media_service.dart';
import '../services/ml_processor.dart';
import 'asset_grid_screen.dart';
import 'widgets/shimmers.dart';

final _media = MediaService();

/// The "Categories" tab — photos auto-grouped by Cloud Vision labels.
class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key, required this.ml});
  final MlProcessor ml;

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  final _db = AppDb.instance;
  final Map<String, List<MediaAsset>> _byCategory = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.ml.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.ml.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final labeled = await _db.labeledAssets();
    final map = <String, List<MediaAsset>>{};
    for (final a in labeled) {
      // Google-style: file each photo under its single best curated category.
      final category = categoryFor(a.labels);
      if (category != null) {
        map.putIfAbsent(category, () => []).add(a);
      }
    }
    // Most-populated categories first.
    final sorted = Map.fromEntries(
      map.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length)),
    );
    if (mounted) {
      setState(() {
        _byCategory
          ..clear()
          ..addAll(sorted);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _byCategory.keys.toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Categories')),
      body: _loading
          ? const ShimmerGrid(tile: 240, count: 8)
          : categories.isEmpty
              ? _empty(context)
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 110),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 240,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.3,
                  ),
                  itemCount: categories.length,
                  itemBuilder: (ctx, i) {
                    final label = categories[i];
                    final assets = _byCategory[label]!;
                    return _CategoryCard(
                      label: label,
                      count: assets.length,
                      coverId: assets.first.id,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              AssetGridScreen(title: label, assets: assets),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ListenableBuilder(
          listenable: widget.ml,
          builder: (_, child) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.category_rounded, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                widget.ml.running
                    ? 'Analyzing ${widget.ml.processed}/${widget.ml.toProcess}…'
                    : 'No categories yet',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Run Analyze (in the People tab) to auto-sort your photos by content.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.label,
    required this.count,
    required this.coverId,
    required this.onTap,
  });
  final String label;
  final int count;
  final String coverId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder(
              future: _media.thumbnail(coverId, px: 400),
              builder: (c, s) => s.data == null
                  ? Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest)
                  : Image.memory(s.data!, fit: BoxFit.cover),
            ),
            // Legibility scrim
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
                  Text('$count photos',
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

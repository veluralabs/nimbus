import 'package:flutter/material.dart';

import '../data/app_db.dart';
import '../labels.dart';
import '../models/media_asset.dart';
import 'photo_viewer.dart';
import 'widgets/asset_thumb.dart';

/// Text search across category labels, filenames, and people names.
/// e.g. "beach", "pdf", "Mom", "screenshot".
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  /// When set, the screen runs this search immediately (e.g. tapping a
  /// category tag in the photo viewer).
  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _db = AppDb.instance;
  final _controller = TextEditingController();
  List<MediaAsset> _results = [];
  List<String> _suggestions = [];
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
    if (widget.initialQuery != null) _search(widget.initialQuery!);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Top categories + people names as tappable suggestion chips.
  Future<void> _loadSuggestions() async {
    final labeled = await _db.labeledAssets();
    final counts = <String, int>{};
    for (final a in labeled) {
      for (final l in cleanLabels(a.labels)) {
        counts[l] = (counts[l] ?? 0) + 1;
      }
    }
    final top = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final people = (await _db.allPersons())
        .where((p) => p.label != null)
        .map((p) => p.label!);
    if (mounted) {
      setState(() {
        _suggestions = [
          ...people,
          ...top.take(12).map((e) => e.key),
        ];
      });
    }
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _controller.text = q;

    // Label/filename matches + person-name matches, deduped by id.
    final byText = await _db.searchAssets(q);
    final seen = {for (final a in byText) a.id};
    final merged = [...byText];
    for (final pid in await _db.personIdsMatching(q)) {
      for (final id in await _db.assetIdsForPerson(pid)) {
        if (seen.add(id)) {
          final a = await _db.assetById(id);
          if (a != null) merged.add(a);
        }
      }
    }
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (mounted) {
      setState(() {
        _results = merged;
        _searched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search photos, people, documents…',
            border: InputBorder.none,
            filled: false,
          ),
          onSubmitted: _search,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(() {
                _controller.clear();
                _results = [];
                _searched = false;
              }),
            ),
        ],
      ),
      body: _searched ? _resultsView() : _suggestionsView(),
    );
  }

  Widget _suggestionsView() {
    if (_suggestions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Run Analyze first to search by category or person.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Try', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _suggestions)
                ActionChip(label: Text(s), onPressed: () => _search(s)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _resultsView() {
    if (_results.isEmpty) {
      return const Center(child: Text('No matches'));
    }
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 120,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: _results.length,
      itemBuilder: (ctx, i) => AssetThumb(
        asset: _results[i],
        onTap: () => Navigator.push(
          ctx,
          MaterialPageRoute(
            builder: (_) => PhotoViewer(assets: _results, initialIndex: i),
          ),
        ),
      ),
    );
  }
}

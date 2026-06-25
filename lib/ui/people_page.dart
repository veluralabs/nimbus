import 'package:flutter/material.dart';

import '../data/app_db.dart';
import '../services/media_service.dart';
import '../services/ml_processor.dart';
import 'asset_grid_screen.dart';
import 'widgets/sheets.dart';
import 'widgets/shimmers.dart';

final _media = MediaService();

/// The "People" tab — face clusters as nameable circles, like Google Photos.
class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key, required this.ml});
  final MlProcessor ml;

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  final _db = AppDb.instance;
  List<Map<String, Object?>> _people = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.ml.addListener(_load);
    _load();
    widget.ml.refreshStats();
    // NOTE: analysis is NOT auto-started here — running ML in the main isolate
    // starves the native thumbnailer and makes the gallery sluggish. The user
    // starts it explicitly (Analyze button) or it runs in the background service.
  }

  @override
  void dispose() {
    widget.ml.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final people = await _db.personSummaries();
    if (mounted) {
      setState(() {
        _people = people;
        _loading = false;
      });
    }
  }

  Future<void> _openPerson(int personId, String? label) async {
    final ids = await _db.assetIdsForPerson(personId);
    final assets = <dynamic>[];
    for (final id in ids) {
      final a = await _db.assetById(id);
      if (a != null) assets.add(a);
    }
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => AssetGridScreen(
        title: label ?? 'Unnamed person',
        assets: assets.cast(),
      ),
    ));
  }

  Future<void> _rename(int personId, String? current) async {
    final name = await textInputSheet(
      context,
      title: 'Name this person',
      hint: 'e.g. Mom, Aarav',
      initial: current ?? '',
    );
    if (name != null && name.isNotEmpty) {
      await _db.renamePerson(personId, name);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('People'),
        actions: [_AnalyzeButton(ml: widget.ml)],
      ),
      body: _loading
          ? const ShimmerPeople()
          : _people.isEmpty
              ? _EmptyState(ml: widget.ml)
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.8,
                  ),
                  itemCount: _people.length,
                  itemBuilder: (ctx, i) {
                    final p = _people[i];
                    final pid = p['person_id'] as int;
                    final label = p['label'] as String?;
                    final count = p['face_count'] as int;
                    final cover = p['cover_asset'] as String?;
                    return GestureDetector(
                      onTap: () => _openPerson(pid, label),
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 44,
                            backgroundColor:
                                Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: ClipOval(
                              child: cover == null
                                  ? const Icon(Icons.person, size: 40)
                                  : FutureBuilder(
                                      future: _media.thumbnail(cover, px: 180),
                                      builder: (c, s) => s.data == null
                                          ? const Icon(Icons.person, size: 40)
                                          : Image.memory(s.data!,
                                              width: 88,
                                              height: 88,
                                              fit: BoxFit.cover),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: () => _rename(pid, label),
                            child: Text(
                              label ?? 'Add name',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: label == null
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                            ),
                          ),
                          Text('$count photos',
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

class _AnalyzeButton extends StatelessWidget {
  const _AnalyzeButton({required this.ml});
  final MlProcessor ml;
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ml,
      builder: (_, child) =>ml.running
          ? Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: ml.toProcess == 0
                        ? null
                        : ml.processed / ml.toProcess),
              ),
            )
          : IconButton(
              tooltip: 'Analyze library',
              icon: const Icon(Icons.auto_awesome),
              onPressed: ml.analyzePending,
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.ml});
  final MlProcessor ml;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ListenableBuilder(
          listenable: ml,
          builder: (_, child) =>Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.people_alt_rounded, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                ml.running
                    ? 'Analyzing ${ml.processed}/${ml.toProcess}…'
                    : 'No people yet',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                ml.note ??
                    (ml.alreadyAnalyzed > 0
                        ? '${ml.alreadyAnalyzed} photos already analyzed. '
                            'Continue to find & group more faces — progress is saved, '
                            'so it resumes where it left off.'
                        : 'Detect and group faces across your photos. '
                            'Name a group once and every photo of that person is tagged.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              if (!ml.running)
                FilledButton.icon(
                  onPressed: ml.analyzePending,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(ml.alreadyAnalyzed > 0
                      ? 'Continue analyzing'
                      : 'Analyze library'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../services/duplicate_finder.dart';
import '../util.dart';
import 'widgets/asset_thumb.dart';
import 'widgets/sheets.dart';

/// Finds and removes duplicate / near-duplicate photos, keeping the
/// highest-resolution copy in each group.
class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  final _finder = DuplicateFinder();

  @override
  void initState() {
    super.initState();
    _finder.scan();
  }

  @override
  void dispose() {
    _finder.dispose();
    super.dispose();
  }

  Future<void> _remove() async {
    final n = _finder.totalDupes;
    final freed = _finder.reclaimBytes;
    final ok = await confirmSheet(
      context,
      title: 'Remove duplicates?',
      message:
          'Delete $n duplicate photos and reclaim ${humanSize(freed)}. '
          'The best (highest-resolution) copy in each set is kept. '
          'Removed copies stay browsable as thumbnails.',
      confirmLabel: 'Remove',
      icon: Icons.auto_delete_rounded,
      danger: true,
    );
    if (!ok) return;
    final removed = await _finder.removeDuplicates();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed $removed duplicates, freed ${humanSize(freed)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicates')),
      body: ListenableBuilder(
        listenable: _finder,
        builder: (context, _) {
          if (_finder.scanning) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    value: _finder.totalToScan == 0
                        ? null
                        : _finder.scanned / _finder.totalToScan,
                  ),
                  const SizedBox(height: 16),
                  Text('Scanning ${_finder.scanned}/${_finder.totalToScan}…'),
                ],
              ),
            );
          }
          if (_finder.groups.isEmpty) {
            return const Center(child: Text('No duplicates found 🎉'));
          }
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _finder.groups.length,
                  itemBuilder: (ctx, i) => _GroupTile(group: _finder.groups[i]),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _remove,
                    icon: const Icon(Icons.auto_delete_rounded),
                    label: Text(
                        'Remove ${_finder.totalDupes} duplicates • free ${humanSize(_finder.reclaimBytes)}'),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({required this.group});
  final DuplicateGroup group;

  @override
  Widget build(BuildContext context) {
    final all = [group.keeper, ...group.dupes];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${all.length} similar • keeping highest-res',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: all.length,
                separatorBuilder: (_, i) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final isKeeper = i == 0;
                  return SizedBox(
                    width: 84,
                    child: Stack(
                      children: [
                        Positioned.fill(child: AssetThumb(asset: all[i])),
                        if (isKeeper)
                          Positioned(
                            left: 4,
                            bottom: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.green,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text('KEEP',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800)),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

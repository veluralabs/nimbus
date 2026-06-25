import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../config.dart';
import '../services/gcs_client.dart';
import '../theme.dart';
import '../util.dart';
import 'widgets/glass.dart';
import 'widgets/shimmers.dart';

/// Live browser for what's actually in your cloud bucket — total used, object
/// count, and a tappable list. Images open from the cloud.
class CloudBrowserScreen extends StatefulWidget {
  const CloudBrowserScreen({super.key, required this.uid});
  final String uid;

  @override
  State<CloudBrowserScreen> createState() => _CloudBrowserScreenState();
}

class _CloudBrowserScreenState extends State<CloudBrowserScreen> {
  final _gcs = GcsClient();
  List<({String name, int size})> _objects = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _gcs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _gcs.init();
      final list = await _gcs.listObjects(Config.userPrefix(widget.uid));
      list.sort((a, b) => b.size.compareTo(a.size));
      if (mounted) setState(() { _objects = list; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  int get _totalBytes => _objects.fold(0, (s, o) => s + o.size);

  String _basename(String name) {
    final seg = name.split('/').last;
    final us = seg.indexOf('_');
    return us >= 0 ? seg.substring(us + 1) : seg;
  }

  String _kind(String name) {
    final parts = name.split('/');
    return parts.length > 2 ? parts[2] : 'file';
  }

  IconData _icon(String kind) => switch (kind) {
        'video' => Icons.movie_rounded,
        'audio' => Icons.audiotrack_rounded,
        'document' => Icons.description_rounded,
        _ => Icons.image_rounded,
      };

  Future<void> _open(({String name, int size}) o) async {
    if (_kind(o.name) != 'image') return;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(12),
        child: FutureBuilder<List<int>>(
          future: _gcs.download(o.name),
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                  height: 300, child: Center(child: ShimmerBox(height: 280)));
            }
            if (snap.data == null) {
              return const SizedBox(
                  height: 200,
                  child: Center(child: Text('Could not load',
                      style: TextStyle(color: Colors.white70))));
            }
            return InteractiveViewer(
                child: Image.memory(Uint8List.fromList(snap.data!)));
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Cloud storage')),
        body: _loading
            ? const ShimmerList()
            : _error != null
                ? Center(child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Could not reach your cloud.\n$_error',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant))))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        Glass(
                          radius: 22,
                          padding: const EdgeInsets.all(18),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                    gradient: NimbusTheme.brandGradient,
                                    borderRadius: BorderRadius.circular(14)),
                                child: const Icon(Icons.cloud_rounded,
                                    color: Colors.white),
                              ),
                              const SizedBox(width: 16),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(humanSize(_totalBytes),
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(fontWeight: FontWeight.w800)),
                                  Text('${_objects.length} objects in your bucket',
                                      style: TextStyle(
                                          color: scheme.onSurfaceVariant,
                                          fontSize: 13)),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        for (final o in _objects)
                          Card(
                            child: ListTile(
                              leading: Icon(_icon(_kind(o.name)),
                                  color: scheme.primary),
                              title: Text(_basename(o.name),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  '${_kind(o.name)} • ${humanSize(o.size)}'),
                              trailing: _kind(o.name) == 'image'
                                  ? const Icon(Icons.open_in_full_rounded, size: 18)
                                  : null,
                              onTap: () => _open(o),
                            ),
                          ),
                      ],
                    ),
                  ),
      ),
    );
  }
}

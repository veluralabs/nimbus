import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../data/app_db.dart';
import '../models/media_asset.dart';
import 'media_service.dart';

/// A set of near-identical photos: the highest-value [keeper] plus [dupes]
/// that can be removed to reclaim space.
class DuplicateGroup {
  DuplicateGroup(this.keeper, this.dupes);
  final MediaAsset keeper;
  final List<MediaAsset> dupes;
  int get reclaimBytes => dupes.fold(0, (s, a) => s + a.size);
}

/// Finds duplicate / near-duplicate images using a 64-bit average perceptual
/// hash (aHash) + Hamming distance, then ranks each group to keep the most
/// valuable copy (highest resolution, then largest file).
class DuplicateFinder extends ChangeNotifier {
  final _db = AppDb.instance;
  final _media = MediaService();

  /// Max Hamming distance to treat two images as duplicates (0 = identical
  /// hash). 0–5 ≈ visually the same shot; higher = looser.
  static const int threshold = 5;

  bool scanning = false;
  int scanned = 0;
  int totalToScan = 0;
  List<DuplicateGroup> groups = [];

  int get totalDupes => groups.fold(0, (s, g) => s + g.dupes.length);
  int get reclaimBytes => groups.fold(0, (s, g) => s + g.reclaimBytes);

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    scanned = 0;
    groups = [];
    notifyListeners();

    final images = (await _db.allAssets())
        .where((a) => a.kind == MediaKind.image && !_isGone(a))
        .toList();
    totalToScan = images.length;
    notifyListeners();

    // Compute (asset, hash, area) for each image.
    final entries = <_HashEntry>[];
    for (final a in images) {
      final h = await _hash(a);
      if (h != null) {
        entries.add(_HashEntry(a, h, await _area(a), a.size));
      }
      scanned++;
      if (scanned % 10 == 0) notifyListeners();
    }

    // Multi-index hashing: split the 64-bit hash into (threshold+1) bands.
    // By the pigeonhole principle, any two hashes within `threshold` bits must
    // match exactly on at least one band — so we only compare candidates that
    // share a band value, instead of all pairs. Union-find merges the matches.
    final parent = List<int>.generate(entries.length, (i) => i);
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) => parent[find(a)] = find(b);

    const bands = threshold + 1; // 6
    final bandBits = (64 / bands).ceil(); // ~11 bits per band
    for (int b = 0; b < bands; b++) {
      final shift = b * bandBits;
      final mask = ((1 << bandBits) - 1) << shift;
      final buckets = <int, List<int>>{};
      for (int i = 0; i < entries.length; i++) {
        buckets.putIfAbsent(entries[i].hash & mask, () => []).add(i);
      }
      for (final bucket in buckets.values) {
        if (bucket.length < 2) continue;
        for (int a = 0; a < bucket.length; a++) {
          for (int c = a + 1; c < bucket.length; c++) {
            if (find(bucket[a]) == find(bucket[c])) continue;
            if (_hamming(entries[bucket[a]].hash, entries[bucket[c]].hash) <=
                threshold) {
              union(bucket[a], bucket[c]);
            }
          }
        }
      }
    }

    // Collect clusters by root.
    final clusters = <int, List<_HashEntry>>{};
    for (int i = 0; i < entries.length; i++) {
      clusters.putIfAbsent(find(i), () => []).add(entries[i]);
    }

    final result = <DuplicateGroup>[];
    for (final cluster in clusters.values) {
      if (cluster.length < 2) continue;
      // Keeper = highest resolution, tie-break on file size.
      cluster.sort((a, b) {
        final byArea = b.area.compareTo(a.area);
        return byArea != 0 ? byArea : b.size.compareTo(a.size);
      });
      result.add(DuplicateGroup(
        cluster.first.asset,
        cluster.skip(1).map((e) => e.asset).toList(),
      ));
    }

    groups = result..sort((a, b) => b.reclaimBytes.compareTo(a.reclaimBytes));
    scanning = false;
    notifyListeners();
  }

  bool _isGone(MediaAsset a) =>
      a.status == SyncStatus.deletedLocal; // already freed

  /// 64-bit average hash from a tiny grayscale version of the image.
  Future<int?> _hash(MediaAsset a) async {
    try {
      img.Image? im;
      if (a.isFileAsset && a.localPath != null) {
        im = img.decodeImage(await File(a.localPath!).readAsBytes());
      } else {
        final bytes = await _media.thumbnail(a.id, px: 64);
        if (bytes != null) im = img.decodeImage(bytes);
      }
      if (im == null) return null;
      final small = img.copyResize(img.grayscale(im), width: 8, height: 8);
      int sum = 0;
      final vals = List<int>.filled(64, 0);
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          final v = small.getPixel(x, y).r.toInt();
          vals[y * 8 + x] = v;
          sum += v;
        }
      }
      final avg = sum / 64;
      int bits = 0;
      for (int i = 0; i < 64; i++) {
        if (vals[i] >= avg) bits |= (1 << i);
      }
      return bits;
    } catch (_) {
      return null;
    }
  }

  Future<int> _area(MediaAsset a) async {
    if (a.isFileAsset) return a.size; // proxy when no dimensions available
    final e = await _media.entity(a.id);
    return e == null ? 0 : e.width * e.height;
  }

  int _hamming(int a, int b) {
    int x = a ^ b, count = 0;
    while (x != 0) {
      count += x & 1;
      x >>= 1;
    }
    return count;
  }

  /// Frees space by deleting the duplicates (keeping each group's keeper),
  /// caching a thumbnail first so they still show in the gallery.
  Future<int> removeDuplicates() async {
    int removed = 0;
    for (final g in groups) {
      for (final dup in g.dupes) {
        try {
          dup.thumbPath ??= await _media.cacheThumb(dup);
          if (dup.isFileAsset && dup.localPath != null) {
            await File(dup.localPath!).delete();
          } else {
            await _media.deleteAssets([dup.id]);
          }
          dup.status = SyncStatus.deletedLocal;
          await _db.updateAsset(dup);
          removed++;
        } catch (_) {/* skip on failure */}
      }
    }
    groups = [];
    notifyListeners();
    return removed;
  }
}

class _HashEntry {
  _HashEntry(this.asset, this.hash, this.area, this.size);
  final MediaAsset asset;
  final int hash;
  final int area;
  final int size;
}

import '../data/app_db.dart';
import '../models/media_asset.dart';
import 'face_embedder.dart';

/// Greedy online clustering of face embeddings into people.
///
/// For each unassigned face, compare against the running centroid of each
/// existing person; if the best cosine similarity clears [threshold], join that
/// person, otherwise start a new one. Simple, incremental, and good enough for
/// a personal library — no need to hold all pairwise distances in memory.
class FaceClusterer {
  FaceClusterer(this._db);
  final AppDb _db;

  /// Cosine threshold to JOIN an existing cluster (greedy pass).
  static const double threshold = 0.60;

  /// Centroid-to-centroid threshold to MERGE two clusters (agglomerative pass).
  /// Centroids are averages, so this is more stable than single faces.
  static const double mergeThreshold = 0.58;

  /// Re-clusters faces: a greedy assignment pass, then an agglomerative merge
  /// pass that combines fragmented clusters of the same person (this is the big
  /// quality win over pure greedy clustering). Returns faces newly assigned.
  Future<int> clusterUnassigned() async {
    final faces =
        (await _db.allFaces()).where((f) => f.embedding.isNotEmpty).toList();
    if (faces.isEmpty) return 0;

    final centroids = <int, List<double>>{};
    final counts = <int, int>{};
    for (final f in faces.where((f) => f.personId != null)) {
      _accumulate(centroids, counts, f.personId!, f.embedding);
    }

    int assigned = 0;
    for (final f in faces.where((f) => f.personId == null)) {
      int? bestPerson;
      double best = -1;
      centroids.forEach((pid, c) {
        final sim = FaceEmbedder.cosine(f.embedding, _normalized(c));
        if (sim > best) {
          best = sim;
          bestPerson = pid;
        }
      });
      int personId;
      if (bestPerson != null && best >= threshold) {
        personId = bestPerson!;
      } else {
        personId = await _db.createPerson();
        centroids[personId] = List.filled(f.embedding.length, 0.0);
        counts[personId] = 0;
      }
      await _db.assignFacePerson(f.id!, personId);
      _accumulate(centroids, counts, personId, f.embedding);
      assigned++;
    }

    await _mergePass();
    return assigned;
  }

  /// Agglomerative merge: union person-clusters whose centroids are close, then
  /// reassign faces to the surviving id and delete the absorbed people.
  Future<void> _mergePass() async {
    final faces = (await _db.allFaces())
        .where((f) => f.embedding.isNotEmpty && f.personId != null)
        .toList();
    final byPerson = <int, List<FaceRecord>>{};
    for (final f in faces) {
      byPerson.putIfAbsent(f.personId!, () => []).add(f);
    }
    final persons = byPerson.keys.toList();
    if (persons.length < 2) return;

    final centroids = {
      for (final p in persons)
        p: _normalized(_sum(byPerson[p]!.map((f) => f.embedding)))
    };
    final parent = {for (final p in persons) p: p};
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]!]!;
        x = parent[x]!;
      }
      return x;
    }

    for (int i = 0; i < persons.length; i++) {
      for (int j = i + 1; j < persons.length; j++) {
        final a = persons[i], b = persons[j];
        if (find(a) == find(b)) continue;
        if (FaceEmbedder.cosine(centroids[a]!, centroids[b]!) >= mergeThreshold) {
          parent[find(a)] = find(b);
        }
      }
    }

    for (final p in persons) {
      final root = find(p);
      if (root != p) {
        for (final f in byPerson[p]!) {
          await _db.assignFacePerson(f.id!, root);
        }
        await _db.deletePerson(p);
      }
    }
  }

  List<double> _sum(Iterable<List<double>> vectors) {
    List<double>? acc;
    for (final v in vectors) {
      acc ??= List.filled(v.length, 0.0);
      for (int i = 0; i < v.length; i++) {
        acc[i] += v[i];
      }
    }
    return acc ?? const [];
  }

  void _accumulate(Map<int, List<double>> centroids, Map<int, int> counts,
      int pid, List<double> emb) {
    final c = centroids.putIfAbsent(pid, () => List.filled(emb.length, 0.0));
    for (int i = 0; i < emb.length; i++) {
      c[i] += emb[i];
    }
    counts[pid] = (counts[pid] ?? 0) + 1;
  }

  /// Mean vector (centroids store the running sum; normalize for comparison).
  List<double> _normalized(List<double> sum) {
    double mag = 0;
    for (final x in sum) {
      mag += x * x;
    }
    mag = mag <= 0 ? 1 : mag;
    final root = mag == 1 ? 1 : _sqrt(mag);
    return sum.map((x) => x / root).toList();
  }

  double _sqrt(double v) {
    double x = v, last = 0;
    while ((x - last).abs() > 1e-9) {
      last = x;
      x = (x + v / x) / 2;
    }
    return x;
  }
}

/// Summary row for the People tab.
class PersonSummary {
  PersonSummary(this.personId, this.label, this.faceCount, this.coverAssetId);
  final int personId;
  final String? label;
  final int faceCount;
  final String? coverAssetId;
}

/// A bucket of assets that share a category label, for the Categories tab.
class CategoryGroup {
  CategoryGroup(this.label, this.assets);
  final String label;
  final List<MediaAsset> assets;
}

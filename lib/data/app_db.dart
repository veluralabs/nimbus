import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/media_asset.dart';

/// Local index: the single source of truth for what's been seen, uploaded,
/// labeled, and grouped. Enables dedup (never re-upload) and offline browse.
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'photos_index.db');
    return openDatabase(
      path,
      version: 4,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onUpgrade: (d, oldV, newV) async {
        if (oldV < 2) {
          await d.execute(
              "ALTER TABLE assets ADD COLUMN kind TEXT NOT NULL DEFAULT 'image'");
          await d.execute('ALTER TABLE assets ADD COLUMN thumb_path TEXT');
          await d.execute(
              "UPDATE assets SET kind = 'video' WHERE is_video = 1");
        }
        if (oldV < 3) {
          await d.execute(
              'CREATE TABLE deleted_ids (id TEXT PRIMARY KEY)');
        }
        if (oldV < 4) {
          await d.execute(
              'ALTER TABLE assets ADD COLUMN accessible INTEGER NOT NULL DEFAULT 1');
        }
      },
      onCreate: (d, _) async {
        await d.execute('CREATE TABLE deleted_ids (id TEXT PRIMARY KEY)');
        await d.execute('''
          CREATE TABLE assets (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            is_video INTEGER NOT NULL,
            kind TEXT NOT NULL DEFAULT 'image',
            size INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            local_path TEXT,
            md5 TEXT,
            status TEXT NOT NULL,
            remote_path TEXT,
            thumb_path TEXT,
            labels TEXT,
            vision_done INTEGER NOT NULL DEFAULT 0,
            faces_done INTEGER NOT NULL DEFAULT 0,
            accessible INTEGER NOT NULL DEFAULT 1
          )''');
        await d.execute(
            'CREATE INDEX idx_assets_status ON assets(status)');
        await d.execute('''
          CREATE TABLE persons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            label TEXT,
            cover_face_id INTEGER
          )''');
        await d.execute('''
          CREATE TABLE faces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            asset_id TEXT NOT NULL,
            box TEXT NOT NULL,
            embedding TEXT NOT NULL,
            person_id INTEGER,
            FOREIGN KEY(asset_id) REFERENCES assets(id) ON DELETE CASCADE,
            FOREIGN KEY(person_id) REFERENCES persons(id) ON DELETE SET NULL
          )''');
        await d.execute(
            'CREATE INDEX idx_faces_person ON faces(person_id)');
      },
    );
  }

  // ---- assets ----

  /// Insert assets discovered on device, ignoring ones we already track
  /// (so existing upload/label state is preserved). Returns count of new rows.
  Future<int> upsertNewAssets(List<MediaAsset> assets) async {
    final d = await db;
    // Never re-add items the user explicitly deleted (the MediaStore index can
    // lag behind a delete, which would otherwise resurrect them).
    final tomb = (await d.query('deleted_ids', columns: ['id']))
        .map((r) => r['id'] as String)
        .toSet();
    int added = 0;
    final batch = d.batch();
    for (final a in assets) {
      if (tomb.contains(a.id)) continue;
      batch.insert('assets', a.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final results = await batch.commit();
    for (final r in results) {
      if (r is int && r > 0) added++;
    }
    return added;
  }

  Future<void> updateAsset(MediaAsset a) async {
    final d = await db;
    await d.update('assets', a.toMap(), where: 'id = ?', whereArgs: [a.id]);
  }

  /// Prunes rows WITHOUT tombstoning (for orphans — files that vanished from
  /// MediaStore, e.g. deleted outside the app). They can return if legit.
  Future<void> pruneRows(List<String> ids) async {
    if (ids.isEmpty) return;
    final d = await db;
    const chunk = 400;
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(i, (i + chunk).clamp(0, ids.length));
      final ph = List.filled(part.length, '?').join(',');
      await d.delete('assets', where: 'id IN ($ph)', whereArgs: part);
    }
  }

  /// Marks rows accessible/inaccessible in bulk. Inaccessible = our app can't
  /// read the bytes (cloned-app storage). We also reset any falsely-"uploaded"
  /// status back to pending, since such items were never actually read/uploaded
  /// (a same-named cloud object can match them during reconciliation).
  Future<void> setAccessible(List<String> ids, bool value) async {
    if (ids.isEmpty) return;
    final d = await db;
    const chunk = 400;
    for (var i = 0; i < ids.length; i += chunk) {
      final part = ids.sublist(i, (i + chunk).clamp(0, ids.length));
      final ph = List.filled(part.length, '?').join(',');
      if (value) {
        await d.rawUpdate(
            'UPDATE assets SET accessible = 1 WHERE id IN ($ph)', part);
      } else {
        // Demote false "uploaded"/"uploading" -> pending; keep deletedLocal
        // (those were genuinely offloaded earlier and have a cached thumb).
        await d.rawUpdate(
            "UPDATE assets SET accessible = 0, "
            "status = CASE WHEN status IN ('uploaded','uploading') "
            "THEN 'pending' ELSE status END, remote_path = NULL "
            'WHERE id IN ($ph)',
            part);
      }
    }
  }

  /// Removes assets from the index entirely (used by an explicit Delete, so the
  /// item disappears from the gallery — distinct from the "free up space"
  /// offload which keeps a deletedLocal thumbnail).
  Future<void> removeAssets(List<String> ids) async {
    if (ids.isEmpty) return;
    final d = await db;
    final placeholders = List.filled(ids.length, '?').join(',');
    await d.delete('assets', where: 'id IN ($placeholders)', whereArgs: ids);
    // Tombstone so a rescan can't resurrect them.
    final batch = d.batch();
    for (final id in ids) {
      batch.insert('deleted_ids', {'id': id},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<List<MediaAsset>> allAssets({String? orderBy}) async {
    final d = await db;
    final rows =
        await d.query('assets', orderBy: orderBy ?? 'created_at DESC');
    return rows.map(MediaAsset.fromMap).toList();
  }

  Future<List<MediaAsset>> assetsWhere(String where, List<Object?> args) async {
    final d = await db;
    final rows = await d.query('assets',
        where: where, whereArgs: args, orderBy: 'created_at DESC');
    return rows.map(MediaAsset.fromMap).toList();
  }

  Future<MediaAsset?> assetById(String id) async {
    final d = await db;
    final rows = await d.query('assets', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : MediaAsset.fromMap(rows.first);
  }

  Future<Map<SyncStatus, int>> statusCounts() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT status, COUNT(*) c FROM assets GROUP BY status');
    final out = {for (final s in SyncStatus.values) s: 0};
    for (final r in rows) {
      out[SyncStatus.values.byName(r['status'] as String)] =
          r['c'] as int;
    }
    return out;
  }

  // ---- faces / persons ----

  Future<int> insertFace(FaceRecord f) async {
    final d = await db;
    return d.insert('faces', f.toMap());
  }

  Future<List<FaceRecord>> allFaces() async {
    final d = await db;
    final rows = await d.query('faces');
    return rows.map(FaceRecord.fromMap).toList();
  }

  Future<void> assignFacePerson(int faceId, int personId) async {
    final d = await db;
    await d.update('faces', {'person_id': personId},
        where: 'id = ?', whereArgs: [faceId]);
  }

  Future<int> createPerson({String? label}) async {
    final d = await db;
    return d.insert('persons', {'label': label});
  }

  Future<void> deletePerson(int id) async {
    final d = await db;
    await d.delete('persons', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> renamePerson(int personId, String label) async {
    final d = await db;
    await d.update('persons', {'label': label},
        where: 'id = ?', whereArgs: [personId]);
  }

  Future<List<Person>> allPersons() async {
    final d = await db;
    final rows = await d.query('persons');
    return rows.map(Person.fromMap).toList();
  }

  /// People with at least one face: id, label, face count, a cover asset id.
  /// Ordered by most-photographed first.
  Future<List<Map<String, Object?>>> personSummaries() async {
    final d = await db;
    return d.rawQuery('''
      SELECT p.id AS person_id, p.label AS label,
             COUNT(f.id) AS face_count, MIN(f.asset_id) AS cover_asset
      FROM persons p
      JOIN faces f ON f.person_id = p.id
      GROUP BY p.id
      HAVING face_count > 0
      ORDER BY face_count DESC
    ''');
  }

  /// Distinct asset ids that contain the given person (for their photo grid).
  Future<List<String>> assetIdsForPerson(int personId) async {
    final d = await db;
    final rows = await d.rawQuery(
      'SELECT DISTINCT asset_id FROM faces WHERE person_id = ?',
      [personId],
    );
    return rows.map((r) => r['asset_id'] as String).toList();
  }

  /// Approximate cloud storage used by this user: total bytes + item count of
  /// everything successfully uploaded (still on device or freed). Computed from
  /// the local index, so it's instant and offline.
  Future<({int bytes, int count})> cloudUsage() async {
    final d = await db;
    final rows = await d.rawQuery(
      "SELECT COALESCE(SUM(size),0) b, COUNT(*) c FROM assets WHERE status IN ('uploaded','deletedLocal')",
    );
    return (bytes: (rows.first['b'] as int), count: (rows.first['c'] as int));
  }

  /// Clears all analysis results so Analyze can run fresh: wipes category
  /// labels, face records, and people, and resets the per-asset done flags.
  /// Does NOT touch backup state (uploads stay intact).
  /// Clears category labels + people GROUPINGS, but keeps the detected faces +
  /// embeddings (and faces_done) so re-analysis just re-clusters instantly
  /// instead of re-detecting every face from scratch.
  Future<void> resetAnalysis() async {
    final d = await db;
    await d.update('faces', {'person_id': null}); // unassign, keep embeddings
    await d.delete('persons');
    await d.update('assets', {'labels': '[]', 'vision_done': 0});
  }

  /// A true full wipe (re-detect everything) — used only if faces are corrupt.
  Future<void> resetAnalysisHard() async {
    final d = await db;
    await d.delete('faces');
    await d.delete('persons');
    await d.update('assets',
        {'labels': '[]', 'vision_done': 0, 'faces_done': 0});
  }

  Future<int> unassignedFaceCount() async {
    final d = await db;
    final r = await d.rawQuery(
        "SELECT COUNT(*) c FROM faces WHERE person_id IS NULL AND embedding != '[]'");
    return (r.first['c'] as int?) ?? 0;
  }

  /// Free-text search over category labels + filenames.
  Future<List<MediaAsset>> searchAssets(String query) async {
    final d = await db;
    final like = '%${query.trim()}%';
    final rows = await d.query('assets',
        where: 'labels LIKE ? OR name LIKE ?',
        whereArgs: [like, like],
        orderBy: 'created_at DESC');
    return rows.map(MediaAsset.fromMap).toList();
  }

  /// Person ids whose name matches the query (for searching by people).
  Future<List<int>> personIdsMatching(String query) async {
    final d = await db;
    final rows = await d.query('persons',
        columns: ['id'],
        where: 'label LIKE ?',
        whereArgs: ['%${query.trim()}%']);
    return rows.map((r) => r['id'] as int).toList();
  }

  /// Count + total bytes per media kind, for the Files tab "folders".
  Future<List<({MediaKind kind, int count, int bytes})>> kindSummary() async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT kind, COUNT(*) c, COALESCE(SUM(size),0) b FROM assets GROUP BY kind');
    return rows
        .map((r) => (
              kind: kindFromName(r['kind'] as String?),
              count: r['c'] as int,
              bytes: r['b'] as int,
            ))
        .toList();
  }

  Future<int> count(String where, List<Object?> args) async {
    final d = await db;
    final r = await d.rawQuery('SELECT COUNT(*) c FROM assets WHERE $where', args);
    return (r.first['c'] as int?) ?? 0;
  }

  Future<List<MediaAsset>> assetsByKind(MediaKind k) async {
    final d = await db;
    final rows = await d.query('assets',
        where: 'kind = ?', whereArgs: [k.name], orderBy: 'created_at DESC');
    return rows.map(MediaAsset.fromMap).toList();
  }

  /// All assets that have at least one category label (for the Categories tab).
  Future<List<MediaAsset>> labeledAssets() async {
    final d = await db;
    final rows = await d.query('assets',
        where: "labels IS NOT NULL AND labels != '[]'",
        orderBy: 'created_at DESC');
    return rows.map(MediaAsset.fromMap).toList();
  }
}

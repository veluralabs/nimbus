import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'gcs_client.dart';

/// Backs up the local SQLite index to the cloud and restores it on a fresh
/// install — so reinstalling the app recovers ALL state (backup status, faces,
/// people, categories), not just the files.
class DbSync {
  static String _object(String uid) => 'users/$uid/_meta/photos_index.db';

  static Future<File> _dbFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'photos_index.db'));
  }

  /// Uploads the current DB snapshot to the cloud.
  static Future<void> backup(String uid) async {
    final f = await _dbFile();
    if (!await f.exists()) return;
    final gcs = GcsClient();
    try {
      await gcs.init();
      await gcs.uploadBytes(_object(uid), await f.readAsBytes());
    } catch (_) {/* best effort */} finally {
      gcs.dispose();
    }
  }

  /// If the local DB is missing/empty (fresh install), download the cloud copy
  /// and write it into place BEFORE the DB is opened. Returns true on restore.
  static Future<bool> restoreIfFresh(String uid) async {
    final f = await _dbFile();
    // A real, populated DB is comfortably larger than this; a brand-new/empty
    // one isn't — so this reliably detects a fresh install.
    if (await f.exists() && await f.length() > 40000) return false;
    final gcs = GcsClient();
    try {
      await gcs.init();
      final bytes = await gcs.download(_object(uid));
      if (bytes.isEmpty) return false;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false; // no cloud DB yet -> first ever use
    } finally {
      gcs.dispose();
    }
  }
}

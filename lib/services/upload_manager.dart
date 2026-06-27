import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../data/app_db.dart';
import '../models/media_asset.dart';
import 'gcs_client.dart';
import 'media_service.dart';

/// Orchestrates backing up one asset end-to-end:
/// resolve file -> hash -> upload -> verify md5 -> update index -> optional delete.
///
/// Idempotent & resumable: already-backed-up assets are skipped, and the local
/// file is deleted ONLY after a verified, checksum-matched upload.
class UploadManager {
  UploadManager(this._gcs, this._media, this._db, this.uid);

  final GcsClient _gcs;
  final MediaService _media;
  final AppDb _db;

  /// Owner's Firebase uid — namespaces every object so accounts stay separate.
  final String uid;

  /// Object name: `users/{uid}/{kind}/{year}/{month}/{filename}`.
  String _objectName(MediaAsset a, File f) {
    final d = a.createdAt;
    final mm = d.month.toString().padLeft(2, '0');
    final base = p.basename(f.path);
    final tag = a.id.hashCode.toRadixString(16);
    return '${Config.userPrefix(uid)}${a.kind.name}/${d.year}/$mm/${tag}_$base';
  }

  /// Resolves the on-disk file for an asset, whether it's a MediaStore item or
  /// a raw file-asset (document/WhatsApp media).
  Future<File?> _resolveFile(MediaAsset a) async {
    if (a.isFileAsset) {
      final path = a.localPath;
      return path == null ? null : File(path);
    }
    final entity = await _media.entity(a.id);
    return entity?.file;
  }

  /// Process a single asset. Returns the updated asset (also persisted).
  Future<MediaAsset> backupOne(
    MediaAsset a, {
    required bool deleteAfter,
    void Function(MediaAsset)? onChange,
  }) async {
    void persist(SyncStatus s) {
      a.status = s;
      _db.updateAsset(a);
      onChange?.call(a);
    }

    if (a.isSafeInCloud) return a; // resume: nothing to do

    try {
      final file = await _resolveFile(a);
      if (file == null || !await file.exists()) {
        persist(SyncStatus.failed);
        return a;
      }
      a.localPath = file.path;
      a.size = await file.length();

      persist(SyncStatus.uploading);

      final localMd5 = await GcsClient.md5Base64(file);
      final objectName = _objectName(a, file);
      final remoteMd5 = await _gcs.upload(file, objectName);

      if (remoteMd5 == null || remoteMd5 != localMd5) {
        persist(SyncStatus.failed); // checksum mismatch -> keep local
        return a;
      }

      a.md5 = localMd5;
      a.remotePath = objectName;
      persist(SyncStatus.uploaded);

      if (deleteAfter && Config.deletionFeatureEnabled) {
        // Cache a thumbnail first so the gallery still shows it after freeing
        // space, then delete the original from the device.
        a.thumbPath ??= await _media.cacheThumb(a);
        final ok = await _deleteOriginal(a);
        if (ok) persist(SyncStatus.deletedLocal);
      }
      return a;
    } catch (_) {
      persist(SyncStatus.failed);
      return a;
    }
  }

  /// Removes the original from the device: raw files via dart:io, MediaStore
  /// items via the system delete API.
  Future<bool> _deleteOriginal(MediaAsset a) async {
    if (a.isFileAsset) {
      try {
        if (a.localPath != null) await File(a.localPath!).delete();
        return true;
      } on FileSystemException {
        return false;
      }
    }
    return _media.deleteAssets([a.id]);
  }

  /// Backs up every not-yet-safe asset sequentially. [shouldStop] lets the UI
  /// or a background worker cancel cleanly between files.
  Future<void> backupAll(
    List<MediaAsset> assets, {
    required bool deleteAfter,
    bool Function()? shouldStop,
    void Function(MediaAsset)? onChange,
    int paceMs = 0,
  }) async {
    await _gcs.init();
    for (final a in assets) {
      if (shouldStop?.call() ?? false) break;
      await backupOne(a, deleteAfter: deleteAfter, onChange: onChange);
      // Battery/CPU pacing: a short gap between files so a long backup doesn't
      // peg a core or spike power draw. Skipped (0) for foreground/manual runs.
      if (paceMs > 0) await Future.delayed(Duration(milliseconds: paceMs));
    }
  }
}

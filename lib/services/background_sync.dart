import 'package:workmanager/workmanager.dart';

import '../data/app_db.dart';
import '../models/media_asset.dart';
import 'auth_service.dart';
import 'gcs_client.dart';
import 'media_service.dart';
import 'upload_manager.dart';

const kSyncTask = 'cloud_offloader.sync';
const kDeleteAfterKey = 'deleteAfter';

/// Background entry point. Runs in its own isolate, so it rebuilds all services
/// from scratch (no shared state with the UI isolate).
///
/// NOTE: Android forbids unbounded background work. WorkManager runs this in
/// deferrable windows (≈15-min minimum, battery/network constrained). For an
/// active, user-initiated full backup the app uses the foreground path instead;
/// this worker catches up newly-added photos opportunistically.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task != kSyncTask) return true;
    final deleteAfter = (input?[kDeleteAfterKey] as bool?) ?? false;

    // No signed-in user -> nothing to sync in the background.
    final auth = AuthService();
    await auth.restore();
    final uid = auth.user?.uid;
    if (uid == null) return true;

    final db = AppDb.instance;
    final media = MediaService();
    final gcs = GcsClient();

    // Refresh the index with anything new on device, then back up pending.
    final all = await media.listAll();
    await db.upsertNewAssets(all);
    final pending = await db.assetsWhere(
      'status IN (?, ?)',
      [SyncStatus.pending.name, SyncStatus.failed.name],
    );

    final mgr = UploadManager(gcs, media, db, uid);
    try {
      await mgr.backupAll(pending, deleteAfter: deleteAfter);
    } finally {
      gcs.dispose();
    }
    return true;
  });
}

const kAutoBackupPref = 'auto_backup_daily';

/// Enables a daily automatic background backup. Runs only on WiFi (or any
/// network if mobile-data is allowed) and not on low battery — the OS enforces
/// these via WorkManager constraints, so it's battery-friendly.
Future<void> enableDailyBackup({required bool allowMobile, required bool deleteAfter}) async {
  await Workmanager().registerPeriodicTask(
    'daily-backup',
    kSyncTask,
    frequency: const Duration(hours: 24),
    constraints: Constraints(
      networkType: allowMobile ? NetworkType.connected : NetworkType.unmetered,
      requiresBatteryNotLow: true,
    ),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    inputData: {kDeleteAfterKey: deleteAfter},
  );
}

Future<void> disableDailyBackup() =>
    Workmanager().cancelByUniqueName('daily-backup');

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_db.dart';
import 'auth_service.dart';
import 'conditions.dart';
import 'db_sync.dart';
import 'gcs_client.dart';
import 'media_service.dart';
import 'ml_processor.dart';
import 'upload_manager.dart';

/// Foreground service that keeps **uploading and analyzing** even when the app
/// is closed, showing live progress in the status bar. Runs in its own isolate,
/// so it rebuilds every service from scratch.

const _kDeleteAfterPref = 'delete_after_upload';

/// Persist the "free up space after backup" choice so the background isolate
/// can honour it (it can't read the in-memory SyncController).
Future<void> persistDeleteAfter(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kDeleteAfterPref, value);
}

@pragma('vm:entry-point')
void backgroundServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_BackupTaskHandler());
}

class _BackupTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _run();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}

  Future<void> _run() async {
    final auth = AuthService();
    await auth.restore();
    final uid = auth.user?.uid;
    if (uid == null) {
      FlutterForegroundTask.stopService();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final deleteAfter = prefs.getBool(_kDeleteAfterPref) ?? false;

    final db = AppDb.instance;
    final media = MediaService();
    final gcs = GcsClient();

    // Refresh index, then back up everything pending.
    final found = await media.listAll();
    await db.upsertNewAssets(found);
    // accessible = 1 excludes cloned-app (/emulated/999/) items we can't read.
    final pending = await db.assetsWhere(
        "status IN ('pending','failed') AND accessible = 1", const []);

    final mgr = UploadManager(gcs, media, db, uid);
    final total = pending.length;

    // Network/battery gating: pause uploads on mobile data (unless bypassed) or
    // low battery. A periodic check flips the flag so backupAll stops cleanly.
    bool paused = false;
    String reason = '';
    Future<void> checkCond() async {
      final c = await UploadConditions.check();
      paused = !c.ok;
      reason = c.reason;
      if (paused) {
        FlutterForegroundTask.updateService(
            notificationTitle: 'Backup paused', notificationText: reason);
      }
    }

    await checkCond();
    final condTimer =
        Timer.periodic(const Duration(seconds: 8), (_) => checkCond());
    try {
      if (!paused) {
        await mgr.backupAll(
          pending,
          deleteAfter: deleteAfter,
          shouldStop: () => paused,
          onChange: (a) {
            final done = pending.where((x) => x.isSafeInCloud).length;
            FlutterForegroundTask.updateService(
              notificationTitle: 'Backing up your photos',
              notificationText: '$done / $total uploaded',
            );
            FlutterForegroundTask.sendDataToMain(
                {'phase': 'upload', 'done': done, 'total': total});
          },
        );
      }
    } catch (_) {/* keep going */} finally {
      condTimer.cancel();
      gcs.dispose();
    }

    // If uploads were paused by conditions, stop now and retry later (the
    // periodic WorkManager re-runs when conditions are met).
    if (paused) {
      FlutterForegroundTask.sendDataToMain({'phase': 'done'});
      FlutterForegroundTask.stopService();
      return;
    }

    // Then analyze (categories + on-device faces) in the background.
    FlutterForegroundTask.updateService(
      notificationTitle: 'Organizing your library',
      notificationText: 'Finding categories and people…',
    );
    try {
      final ml = MlProcessor();
      ml.addListener(() {
        if (ml.toProcess > 0) {
          FlutterForegroundTask.updateService(
            notificationTitle: 'Organizing your library',
            notificationText: 'Analyzed ${ml.processed} / ${ml.toProcess}',
          );
          FlutterForegroundTask.sendDataToMain(
              {'phase': 'analyze', 'done': ml.processed, 'total': ml.toProcess});
        }
      });
      await ml.analyzePending();
    } catch (_) {/* best effort */}

    // Snapshot the local index to the cloud so a reinstall restores everything.
    await DbSync.backup(uid);

    FlutterForegroundTask.updateService(
      notificationTitle: 'Photos',
      notificationText: 'Backup & organize complete',
    );
    FlutterForegroundTask.sendDataToMain({'phase': 'done'});
    FlutterForegroundTask.stopService();
  }
}

/// One-time channel/notification setup. Call in main().
void initBackgroundService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'anjish_backup',
      channelName: 'Backup & sync',
      channelDescription: 'Uploading and organizing your photos',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      allowWifiLock: true,
    ),
  );
}

/// Starts the background backup+analyze service (idempotent).
Future<void> startBackupService() async {
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    serviceId: 451,
    notificationTitle: 'Anjish',
    notificationText: 'Starting backup…',
    callback: backgroundServiceCallback,
  );
}

Future<void> stopBackupService() => FlutterForegroundTask.stopService();

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_db.dart';
import '../models/media_asset.dart';
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

    // Network/battery gating, re-evaluated continuously. CRITICAL: when the
    // screen turns off many phones (esp. Oppo/ColorOS) drop the Wi-Fi radio for
    // a moment, which used to make us pause AND stop the service — so the whole
    // backup died on screen-off. Now we keep the foreground service alive and
    // simply WAIT, resuming automatically the instant conditions return.
    bool paused = false;
    String reason = '';
    Future<void> checkCond() async {
      final c = await UploadConditions.check();
      paused = !c.ok;
      reason = c.reason;
    }

    final condTimer =
        Timer.periodic(const Duration(seconds: 8), (_) => checkCond());

    // Throttle status-bar notification updates. Updating per-file trips
    // Android's notification rate limit ("Shedding ..." in logcat) and makes the
    // progress counter stutter; once every ~2s is smooth and cheap.
    DateTime lastNotif = DateTime.fromMillisecondsSinceEpoch(0);

    // Enumerate the device library ONCE up front (it's expensive). The loop
    // below only re-queries the DB for what's still pending — re-scanning
    // MediaStore on every resume would waste CPU/battery.
    final found = await media.listAll();
    await db.upsertNewAssets(found);

    try {
      // Keep working across screen-off / network blips until nothing is left.
      while (true) {
        await checkCond();
        if (paused) {
          FlutterForegroundTask.updateService(
              notificationTitle: 'Backup paused', notificationText: reason);
          await Future.delayed(const Duration(seconds: 20));
          continue; // re-evaluate; do NOT stop the service
        }

        final pending = await db.assetsWhere(
            "status IN ('pending','failed')", const []);
        if (pending.isEmpty) break; // everything is safe in the cloud

        // Count what's already uploaded so we can detect "no progress" passes
        // and avoid spinning forever on permanently-failing items.
        final before = await db.statusCounts();
        final safeBefore = (before[SyncStatus.uploaded] ?? 0) +
            (before[SyncStatus.deletedLocal] ?? 0);

        final gcs = GcsClient();
        try {
          final mgr = UploadManager(gcs, media, db, uid);
          await mgr.backupAll(
            pending,
            deleteAfter: deleteAfter,
            // Pace uploads so we don't peg a CPU core / drain battery: a short
            // gap between files keeps average CPU well under the ~20% target.
            paceMs: 60,
            shouldStop: () => paused, // breaks cleanly; outer loop waits + resumes
            onChange: (a) {
              final now = DateTime.now();
              if (now.difference(lastNotif).inMilliseconds < 2000) return;
              lastNotif = now;
              final done = pending.where((x) => x.isSafeInCloud).length;
              FlutterForegroundTask.updateService(
                notificationTitle: 'Backing up your photos',
                notificationText: 'Uploaded $done / ${pending.length}',
              );
              FlutterForegroundTask.sendDataToMain(
                  {'phase': 'upload', 'done': done, 'total': pending.length});
            },
          );
        } catch (_) {/* transient — outer loop retries */} finally {
          gcs.dispose();
        }
        if (paused) continue; // conditions dropped mid-batch; wait then resume

        // Completed a full pass while unpaused: if nothing new got uploaded,
        // the remainder are permanent failures — stop rather than spin forever.
        final after = await db.statusCounts();
        final safeAfter = (after[SyncStatus.uploaded] ?? 0) +
            (after[SyncStatus.deletedLocal] ?? 0);
        if (safeAfter <= safeBefore) break;
      }
    } finally {
      condTimer.cancel();
    }

    // Snapshot the local index to the cloud so a reinstall restores everything.
    try {
      await DbSync.backup(uid);
    } catch (_) {/* best effort */}

    // Heavy ML analysis (TFLite + face decode) is memory-hungry and, with the
    // screen off on battery, gets the app low-memory-killed (the "crash"). Only
    // run it while CHARGING — typically overnight — so the BACKUP itself always
    // completes reliably. Otherwise it runs next time the app is open/charging.
    final battery = Battery();
    final st = await battery.batteryState;
    final charging =
        st == BatteryState.charging || st == BatteryState.full;
    if (charging) {
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
            FlutterForegroundTask.sendDataToMain({
              'phase': 'analyze',
              'done': ml.processed,
              'total': ml.toProcess
            });
          }
        });
        await ml.analyzePending();
      } catch (_) {/* best effort */}
    }

    FlutterForegroundTask.updateService(
      notificationTitle: 'Photos',
      notificationText: 'Backup complete',
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
      // Hold a CPU wake lock + Wi-Fi lock so the OS can't freeze the upload
      // isolate or power down the radio while the screen is off.
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// Starts the background backup+analyze service (idempotent).
Future<void> startBackupService() async {
  if (await FlutterForegroundTask.isRunningService) return;
  // Ask the OS (once) to stop freezing/killing us in Doze. Without this, OEM
  // battery managers suspend the service the moment the screen turns off.
  try {
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  } catch (_) {/* not all OEMs expose this; the foreground service still runs */}
  await FlutterForegroundTask.startService(
    serviceId: 451,
    notificationTitle: 'Anjish',
    notificationText: 'Starting backup…',
    callback: backgroundServiceCallback,
  );
}

Future<void> stopBackupService() => FlutterForegroundTask.stopService();

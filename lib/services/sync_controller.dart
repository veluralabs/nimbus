import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../data/app_db.dart';
import '../models/media_asset.dart';
import 'background_service.dart';
import 'document_scanner.dart';
import 'gcs_client.dart';
import 'media_service.dart';

/// A date-grouped run of photos/videos for the timeline (precomputed once when
/// the asset list changes, NOT on every rebuild).
class TimelineSection {
  TimelineSection(this.label, this.startIndex, this.assets);
  final String label;
  final int startIndex; // index into visibleAssets, for the viewer
  final List<MediaAsset> assets;
}

/// Drives the gallery. Backup + analyze run in a foreground service so they
/// continue when the app is closed (with a status-bar notification); this
/// controller starts that service and mirrors its progress for the UI.
class SyncController extends ChangeNotifier {
  SyncController({required this.uid}) {
    FlutterForegroundTask.addTaskDataCallback(_onServiceData);
  }
  final String uid;

  final _db = AppDb.instance;
  final _media = MediaService();
  final _docs = DocumentScanner();

  List<MediaAsset> assets = [];
  // Photos+videos only, and date-grouped — both precomputed when assets change.
  List<MediaAsset> visibleAssets = [];
  List<TimelineSection> sections = [];
  bool scanning = false;
  bool syncing = false;
  bool deleteAfterUpload = false;

  /// Sets the asset list and recomputes the (expensive) timeline grouping ONCE,
  /// instead of regrouping ~96k assets on every widget rebuild.
  void _setAssets(List<MediaAsset> list) {
    assets = list;
    visibleAssets = list
        .where((a) => a.kind == MediaKind.image || a.kind == MediaKind.video)
        .toList();
    final out = <TimelineSection>[];
    int i = 0;
    while (i < visibleAssets.length) {
      final label = _dateLabel(visibleAssets[i].createdAt);
      final start = i;
      while (i < visibleAssets.length &&
          _dateLabel(visibleAssets[i].createdAt) == label) {
        i++;
      }
      out.add(TimelineSection(label, start, visibleAssets.sublist(start, i)));
    }
    sections = out;
  }

  static const _months = [
    'January','February','March','April','May','June',
    'July','August','September','October','November','December'
  ];
  String _dateLabel(DateTime d) {
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (d.year == now.year) return '${_months[d.month - 1]} ${d.day}';
    return '${_months[d.month - 1]} ${d.year}';
  }

  // Live progress mirrored from the background service.
  int bgDone = 0;
  int bgTotal = 0;
  String bgPhase = '';

  // Pinch-to-zoom grid density (max tile width). Larger = bigger tiles.
  double gridExtent = 120;
  double _baseExtent = 120;
  void startZoom() => _baseExtent = gridExtent;
  void zoom(double scale) {
    // Fingers apart (scale > 1) -> zoom in -> bigger tiles.
    gridExtent = (_baseExtent * scale).clamp(70.0, 280.0);
    notifyListeners();
  }

  // Multi-select state.
  final Set<String> selected = {};
  bool get selecting => selected.isNotEmpty;
  List<MediaAsset> get selectedAssets =>
      assets.where((a) => selected.contains(a.id)).toList();

  void toggleSelect(String id) {
    selected.contains(id) ? selected.remove(id) : selected.add(id);
    notifyListeners();
  }

  void clearSelection() {
    selected.clear();
    notifyListeners();
  }

  /// Reloads the asset list from the DB (e.g. after an AI edit adds a new copy).
  Future<void> refreshFromDb() async {
    _setAssets(await _db.allAssets());
    notifyListeners();
  }

  Future<void> removeFromView(List<String> ids) async {
    await _db.removeAssets(ids);
    final gone = ids.toSet();
    selected.removeAll(gone);
    _setAssets(assets.where((a) => !gone.contains(a.id)).toList());
    notifyListeners();
  }

  int get total => assets.length;
  int get backedUp => assets.where((a) => a.isSafeInCloud).length;
  int get failed => assets.where((a) => a.status == SyncStatus.failed).length;
  int get pending => total - backedUp;

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
    super.dispose();
  }

  bool hasAllFilesAccess = false;

  bool reconciling = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // One-time repair: an earlier build wrongly flagged cloned-app
    // (/emulated/999/) files as "can't access" and reset their backed-up status,
    // even though they ARE readable (via the content resolver) and were already
    // uploaded. Clear the flag, restore accessibility, and force a re-reconcile
    // so those files get re-matched to the cloud instead of needlessly re-sent.
    if (!(prefs.getBool('clone_revert_v3') ?? false)) {
      await _db.clearInaccessibleFlags();
      await prefs.remove('cloud_reconciled_$uid');
      await prefs.setBool('clone_revert_v3', true);
    }
    // Show the cached library instantly on cold start...
    _setAssets(await _db.allAssets());
    syncing = await FlutterForegroundTask.isRunningService;
    notifyListeners();
    // ...then refresh from the device and, once per install, reconcile backup
    // state with the cloud so a reinstall doesn't re-upload everything.
    ensureFileAccess().then((_) async {
      await scan();
      if (!(prefs.getBool('cloud_reconciled_$uid') ?? false)) {
        await reconcileWithCloud();
        await prefs.setBool('cloud_reconciled_$uid', true);
      }
    });
  }

  /// Matches local photos against what's already in the bucket (by filename)
  /// and marks them backed-up — so a fresh install shows real progress instead
  /// of re-uploading the whole library.
  Future<void> reconcileWithCloud() async {
    if (reconciling) return;
    reconciling = true;
    notifyListeners();
    final gcs = GcsClient();
    try {
      await gcs.init();
      final names = await gcs.listObjectNames(Config.userPrefix(uid));
      // Object: users/{uid}/{kind}/{yyyy}/{mm}/{hash}_{basename}
      final cloudByBasename = <String, String>{};
      for (final name in names) {
        final seg = name.split('/').last;
        final us = seg.indexOf('_');
        final base = (us >= 0 ? seg.substring(us + 1) : seg).toLowerCase();
        cloudByBasename[base] = name;
      }
      if (cloudByBasename.isNotEmpty) {
        final pending = await _db.assetsWhere("status = 'pending'", const []);
        for (final a in pending) {
          final obj = cloudByBasename[a.name.toLowerCase()];
          if (obj != null) {
            a.status = SyncStatus.uploaded;
            a.remotePath = obj;
            await _db.updateAsset(a);
          }
        }
        _setAssets(await _db.allAssets());
      }
    } catch (_) {/* best effort */} finally {
      gcs.dispose();
      reconciling = false;
      notifyListeners();
    }
  }

  /// Requests "All files access" (MANAGE_EXTERNAL_STORAGE) so the app can read,
  /// back up, and DELETE files across the device — including documents and bulk
  /// deletes without a per-file system prompt. Opens the system toggle if needed.
  Future<void> ensureFileAccess() async {
    hasAllFilesAccess = await Permission.manageExternalStorage.isGranted;
    if (!hasAllFilesAccess) {
      final status = await Permission.manageExternalStorage.request();
      hasAllFilesAccess = status.isGranted;
      if (!hasAllFilesAccess) {
        // Android shows the toggle in a settings screen; guide the user there.
        await openAppSettings();
      }
    }
    // Needed to read un-redacted GPS EXIF from gallery photos (Android 10+).
    if (!await Permission.accessMediaLocation.isGranted) {
      await Permission.accessMediaLocation.request();
    }
    notifyListeners();
  }

  Future<void> scan() async {
    scanning = true;
    notifyListeners();
    if (await _media.requestAccess()) {
      final found = await _media.listAll();
      await _db.upsertNewAssets(found);
      // Document/WhatsApp filesystem walk is expensive — only run it at most
      // every 6 hours, not on every cold start.
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt('last_doc_scan') ?? 0;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - last > 6 * 3600 * 1000) {
        try {
          final docs = await _docs.scan();
          await _db.upsertNewAssets(docs);
          await prefs.setInt('last_doc_scan', nowMs);
        } catch (_) {/* doc scan best-effort */}
      }
      _setAssets(await _db.allAssets());
    }
    scanning = false;
    notifyListeners();
  }

  void setDeleteAfter(bool value) {
    deleteAfterUpload = value;
    persistDeleteAfter(value);
    notifyListeners();
  }

  /// Starts the background backup + analyze service.
  Future<void> syncNow() async {
    if (syncing) return;
    await _ensureNotificationPermission();
    await persistDeleteAfter(deleteAfterUpload);
    syncing = true;
    bgPhase = 'upload';
    notifyListeners();
    await startBackupService();
  }

  Future<void> stop() async {
    await stopBackupService();
    syncing = false;
    notifyListeners();
  }

  Future<void> _ensureNotificationPermission() async {
    final p = await FlutterForegroundTask.checkNotificationPermission();
    if (p != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  void _onServiceData(Object data) {
    if (data is! Map) return;
    final phase = data['phase'] as String?;
    if (phase == 'done') {
      bgPhase = 'done';
      syncing = false;
      _db.allAssets().then((a) {
        _setAssets(a);
        notifyListeners();
      });
      return;
    }
    bgPhase = phase ?? bgPhase;
    bgDone = (data['done'] as int?) ?? bgDone;
    bgTotal = (data['total'] as int?) ?? bgTotal;
    // Throttle: progress fires per-asset; rebuilding the gallery 100×/sec is
    // pointless. Coalesce to ~3 updates/sec.
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds >= 300) {
      _lastNotify = now;
      notifyListeners();
    }
  }
}

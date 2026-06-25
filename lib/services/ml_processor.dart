import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_db.dart';
import '../models/media_asset.dart';
import 'face_clustering.dart';
import 'face_detector_service.dart';
import 'face_embedder.dart';
import 'media_service.dart';
import 'vision_service.dart';

/// Runs the on-device + cloud ML pass over the library:
///   for each not-yet-analyzed image:
///     Cloud Vision  -> category labels + face boxes   (persist)
///     TFLite        -> embedding per face             (persist)
///   then cluster all faces -> People groups.
///
/// Images only (videos are skipped for ML). Idempotent: an asset with
/// visionDone == true is not re-analyzed.
class MlProcessor extends ChangeNotifier {
  MlProcessor();

  final _db = AppDb.instance;
  final _media = MediaService();
  final _vision = VisionService();
  final _faceDetector = FaceDetectorService();
  final _embedder = FaceEmbedder();
  late final _clusterer = FaceClusterer(_db);

  bool running = false;
  bool _stop = false;
  int processed = 0;
  int toProcess = 0;
  int facesFound = 0;
  int alreadyAnalyzed = 0; // analyzed in prior runs (resume state)
  int totalImages = 0;
  String? note;

  bool get faceGroupingEnabled => _embedder.isAvailable;

  /// Refreshes resume stats (analyzed / total images) without running anything.
  Future<void> refreshStats() async {
    totalImages = await _db.count("kind = 'image'", const []);
    alreadyAnalyzed =
        await _db.count("kind = 'image' AND vision_done = 1", const []);
    notifyListeners();
  }

  void stop() => _stop = true;

  /// Tell listeners (People/Categories pages) to reload from the DB — e.g.
  /// after a reset clears all analysis results.
  void notifyChanged() => notifyListeners();

  /// Whether to also run paid Cloud Vision category labeling. Read from prefs;
  /// OFF by default so auto-analyze (faces) never costs money.
  static Future<bool> cloudLabelsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('use_cloud_labels') ?? false;
  }

  static Future<void> setCloudLabels(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_cloud_labels', v);
  }

  /// Starts analysis automatically if there's pending work and nothing running.
  Future<void> autoStart() async {
    if (running) return;
    final pendingFaces =
        await _db.count("kind = 'image' AND faces_done = 0", const []);
    final unassigned = await _db.unassignedFaceCount();
    // Detect new faces OR re-cluster ungrouped ones (e.g. after a reset).
    if (pendingFaces > 0 || unassigned > 0) analyzePending();
  }

  Future<void> analyzePending() async {
    if (running) return;
    running = true;
    _stop = false;
    processed = 0;
    facesFound = 0;
    notifyListeners();

    final cloudLabels = await cloudLabelsEnabled();
    try {
      if (cloudLabels) await _vision.init();
      await _embedder.init();
      note = _embedder.isAvailable
          ? null
          : 'Face model not installed — faces are detected but not grouped.';

      totalImages = await _db.count("kind = 'image'", const []);
      // Free faces always run; paid labels only when enabled.
      final where = cloudLabels
          ? "kind = 'image' AND (faces_done = 0 OR vision_done = 0)"
          : "kind = 'image' AND faces_done = 0";
      final pending = await _db.assetsWhere(where, const []);
      toProcess = pending.length;
      alreadyAnalyzed =
          await _db.count("kind = 'image' AND faces_done = 1", const []);
      notifyListeners();

      for (final a in pending) {
        if (_stop) break;
        await _analyzeOne(a, cloudLabels);
        processed++;
        // Cluster incrementally so People fills in AS WE GO.
        if (_embedder.isAvailable && processed % 30 == 0) {
          await _clusterer.clusterUnassigned();
        }
        notifyListeners();
        // Breathe between items so heavy decode/ML work doesn't starve the UI
        // thread and make the device feel sluggish.
        await Future.delayed(const Duration(milliseconds: 25));
      }

      if (_embedder.isAvailable) {
        final n = await _clusterer.clusterUnassigned();
        if (n > 0) note = 'Grouped $n new faces into People.';
        notifyListeners();
      }
    } finally {
      _vision.dispose();
      _embedder.dispose();
      await _faceDetector.dispose();
      running = false;
      notifyListeners();
    }
  }

  Future<void> _analyzeOne(MediaAsset a, bool cloudLabels) async {
    try {
      // Memory-bounded: a native-decoded ~1280px JPEG, never a full-res bitmap.
      final pi = await _media.proportionalImage(a.id, 1280);
      if (pi == null) return;

      // Paid categories via Cloud Vision — only when enabled and not yet done.
      if (cloudLabels && !a.visionDone) {
        final result = await _vision.annotate(pi.bytes);
        a.labels = result.labels;
        a.visionDone = true;
      }

      // Free on-device faces (always, if not yet done). Screenshots are skipped
      // so chat/profile pictures inside them don't pollute People.
      if (!a.facesDone && !_isScreenshot(a)) {
        final entity = await _media.entity(a.id);
        final file = await entity?.file;
        if (file != null) {
          final faces = await _faceDetector.detect(file.path);
          if (faces.isNotEmpty) {
            final work = img.decodeImage(pi.bytes);
            if (work != null) {
              for (final f in faces) {
                if (f.angleY.abs() > 36 || f.angleZ.abs() > 34) continue;
                final s = pi.scale;
                final scaled = FaceBox(f.box.left * s, f.box.top * s,
                    f.box.width * s, f.box.height * s);
                final emb = await _embedder.embed(work, scaled,
                    rollRadians: f.eyeRollRadians);
                await _db.insertFace(FaceRecord(
                  assetId: a.id,
                  box: scaled.toList(),
                  embedding: emb ?? const [],
                ));
                facesFound++;
              }
            }
          }
        }
        a.facesDone = true;
      } else if (_isScreenshot(a)) {
        a.facesDone = true; // mark done so it isn't re-checked every pass
      }
      await _db.updateAsset(a);
    } catch (_) {
      // Leave vision_done = 0 so it retries next pass.
    }
  }

  /// Heuristic: Android screenshots are named "Screenshot…" and/or live in a
  /// Screenshots folder. We skip face detection on them.
  bool _isScreenshot(MediaAsset a) {
    final n = a.name.toLowerCase();
    final p = (a.localPath ?? '').toLowerCase();
    return n.contains('screenshot') || p.contains('screenshot');
  }
}

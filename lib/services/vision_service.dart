import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:googleapis/vision/v1.dart' as vision;
import 'package:googleapis_auth/auth_io.dart';

import '../config.dart';
import '../labels.dart';

/// One face box in original-image pixel coordinates.
class FaceBox {
  FaceBox(this.left, this.top, this.width, this.height);
  final double left, top, width, height;
  List<double> toList() => [left, top, width, height];
}

class VisionResult {
  VisionResult(this.labels);

  /// Category labels, highest-confidence first (e.g. "Beach", "Food").
  final List<String> labels;
}

/// Calls Cloud Vision for label detection only (categorization). Face detection
/// is now done on-device (free) via FaceDetectorService.
class VisionService {
  vision.VisionApi? _api;
  AutoRefreshingAuthClient? _client;

  Future<void> init() async {
    if (_api != null) return;
    final raw = await rootBundle.loadString(Config.serviceAccountAsset);
    final creds = ServiceAccountCredentials.fromJson(
        jsonDecode(raw) as Map<String, dynamic>);
    _client = await clientViaServiceAccount(
        creds, const ['https://www.googleapis.com/auth/cloud-vision']);
    _api = vision.VisionApi(_client!);
  }

  void dispose() {
    _client?.close();
    _client = null;
    _api = null;
  }

  /// Annotates pre-downscaled JPEG bytes for category labels only. Takes bytes
  /// (not a File) so callers can pass a memory-bounded thumbnail instead of a
  /// full-resolution decode. Drops face/anatomy "junk" labels.
  Future<VisionResult> annotate(Uint8List jpegBytes) async {
    final b64 = base64.encode(jpegBytes);

    final req = vision.BatchAnnotateImagesRequest(requests: [
      vision.AnnotateImageRequest(
        image: vision.Image(content: b64),
        features: [vision.Feature(type: 'LABEL_DETECTION', maxResults: 10)],
      ),
    ]);

    final res = await _api!.images.annotate(req);
    final r = res.responses?.first;

    final raw = (r?.labelAnnotations ?? [])
        .where((l) => (l.score ?? 0) >= 0.70)
        .map((l) => l.description ?? '')
        .where((d) => d.isNotEmpty);

    return VisionResult(cleanLabels(raw));
  }
}

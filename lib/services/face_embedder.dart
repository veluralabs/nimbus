import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'vision_service.dart';

/// Computes a face embedding (numeric fingerprint) for a detected face using
/// an on-device MobileFaceNet TFLite model. Embeddings of the same person land
/// close together, which is what the clusterer uses to form "People" groups.
///
/// The model is OPTIONAL at build time: drop a 112x112 -> 192-d MobileFaceNet
/// at assets/models/mobilefacenet.tflite. If it's missing, [isAvailable] is
/// false and the app still detects/counts faces — it just can't group them yet.
class FaceEmbedder {
  static const _assetPath = 'assets/models/mobilefacenet.tflite';

  Interpreter? _interp;
  bool _tried = false;
  bool get isAvailable => _interp != null;

  // Read from the model at load time so we adapt to whatever was dropped in
  // (MobileFaceNet is usually 112x112 -> 192, but don't assume).
  int _inputSize = 112;
  int _embeddingSize = 192;

  Future<void> init() async {
    if (_tried) return;
    _tried = true;
    try {
      final interp = await Interpreter.fromAsset(_assetPath);
      final inShape = interp.getInputTensor(0).shape; // [1, H, W, 3]
      final outShape = interp.getOutputTensor(0).shape; // [1, N]
      if (inShape.length == 4) _inputSize = inShape[1];
      _embeddingSize = outShape.last;
      _interp = interp;
    } catch (_) {
      _interp = null; // model not bundled / incompatible -> grouping disabled
    }
  }

  void dispose() {
    _interp?.close();
    _interp = null;
  }

  /// Crops [box] from [file], runs the model, returns an L2-normalized vector
  /// (or null if the model isn't available or the crop is invalid).
  ///
  /// [rollRadians] (eye tilt) aligns the face so the eyes are horizontal before
  /// embedding — this makes embeddings of the same person far more consistent,
  /// which is what lets clustering actually group them.
  Future<List<double>?> embed(img.Image source, FaceBox box,
      {double rollRadians = 0}) async {
    if (_interp == null) return null;
    img.Image full = source;

    var b = box;
    // De-rotate the whole image so the face is upright, then re-place the box
    // at the image centre of rotation (img.copyRotate rotates about centre).
    if (rollRadians.abs() > 0.08) {
      full = img.copyRotate(full, angle: -rollRadians * 180 / math.pi);
      // After rotation the box no longer maps 1:1; fall back to a centred,
      // slightly padded square around the original box centre.
      final cx = box.left + box.width / 2;
      final cy = box.top + box.height / 2;
      final side = math.max(box.width, box.height) * 1.1;
      b = FaceBox(cx - side / 2, cy - side / 2, side, side);
    }

    // Clamp the box to image bounds, then crop + resize to the model input.
    final x = b.left.clamp(0, full.width - 1).toInt();
    final y = b.top.clamp(0, full.height - 1).toInt();
    final w = b.width.clamp(1, full.width - x).toInt();
    final h = b.height.clamp(1, full.height - y).toInt();
    final crop = img.copyCrop(full, x: x, y: y, width: w, height: h);
    final face = img.copyResize(crop, width: _inputSize, height: _inputSize);

    // [1,112,112,3] float input, normalized to roughly [-1, 1].
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (yy) => List.generate(_inputSize, (xx) {
          final px = face.getPixel(xx, yy);
          return [
            (px.r - 127.5) / 128.0,
            (px.g - 127.5) / 128.0,
            (px.b - 127.5) / 128.0,
          ];
        }),
      ),
    );

    final output =
        List.generate(1, (_) => List.filled(_embeddingSize, 0.0));
    _interp!.run(input, output);
    return _l2normalize(output.first);
  }

  List<double> _l2normalize(List<double> v) {
    double sum = 0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return v;
    return v.map((x) => x / norm).toList();
  }

  /// Cosine similarity of two L2-normalized vectors == dot product.
  static double cosine(List<double> a, List<double> b) {
    double dot = 0;
    final n = math.min(a.length, b.length);
    for (int i = 0; i < n; i++) {
      dot += a[i] * b[i];
    }
    return dot;
  }
}

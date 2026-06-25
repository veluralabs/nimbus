import 'dart:math' as math;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'vision_service.dart' show FaceBox;

/// A detected face with the signals we need for quality gating + alignment.
class FaceInfo {
  FaceInfo({
    required this.box,
    this.leftEye,
    this.rightEye,
    required this.angleY,
    required this.angleZ,
  });

  final FaceBox box;
  final math.Point<double>? leftEye; // image-pixel coords
  final math.Point<double>? rightEye;
  final double angleY; // head yaw (profile when large)
  final double angleZ; // head roll (tilt)

  /// In-plane rotation (radians) to make the eyes horizontal, for alignment.
  double get eyeRollRadians {
    final l = leftEye, r = rightEye;
    if (l == null || r == null) return 0;
    return math.atan2(r.y - l.y, r.x - l.x);
  }
}

/// On-device face detection (ML Kit) with landmarks + classification enabled,
/// so we can (a) skip low-quality faces and (b) align by the eyes before
/// embedding — both are what make clustering actually group the same person.
class FaceDetectorService {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableLandmarks: true,
      enableClassification: true,
      // Detect smaller / group-photo / distant faces (was 0.1 = missed many).
      minFaceSize: 0.04,
    ),
  );

  Future<List<FaceInfo>> detect(String filePath) async {
    final faces = await _detector.processImage(InputImage.fromFilePath(filePath));
    return faces.map((f) {
      final r = f.boundingBox;
      final le = f.landmarks[FaceLandmarkType.leftEye]?.position;
      final re = f.landmarks[FaceLandmarkType.rightEye]?.position;
      return FaceInfo(
        box: FaceBox(r.left, r.top, r.width, r.height),
        leftEye: le == null ? null : math.Point(le.x.toDouble(), le.y.toDouble()),
        rightEye: re == null ? null : math.Point(re.x.toDouble(), re.y.toDouble()),
        angleY: f.headEulerAngleY ?? 0,
        angleZ: f.headEulerAngleZ ?? 0,
      );
    }).toList();
  }

  Future<void> dispose() => _detector.close();
}

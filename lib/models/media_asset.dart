import 'dart:convert';

enum SyncStatus { pending, uploading, uploaded, deletedLocal, failed }

enum MediaKind { image, video, audio, document }

MediaKind kindFromName(String? s) =>
    MediaKind.values.firstWhere((k) => k.name == s, orElse: () => MediaKind.image);

/// One photo/video on the device, plus its backup + ML state.
/// Mirrors a row in the `assets` table.
class MediaAsset {
  MediaAsset({
    required this.id,
    required this.name,
    required this.kind,
    required this.size,
    required this.createdAt,
    this.localPath,
    this.md5,
    this.status = SyncStatus.pending,
    this.remotePath,
    this.thumbPath,
    List<String>? labels,
    this.visionDone = false,
    this.facesDone = false,
    this.accessible = true,
  }) : _labels = labels;

  /// Primary key. For MediaStore items this is the asset id; for raw files
  /// (documents, WhatsApp media) it is `file:<absolute path>`.
  final String id;
  final String name;
  final MediaKind kind;

  bool get isVideo => kind == MediaKind.video;
  bool get isImage => kind == MediaKind.image;

  /// Raw-file assets (documents/audio scanned from disk) aren't in MediaStore;
  /// they're handled via [localPath] directly instead of an AssetEntity.
  bool get isFileAsset => id.startsWith('file:');

  /// Bytes. 0 until the file is resolved before upload.
  int size;
  final DateTime createdAt;

  /// Resolved file path; for file-assets this is always set.
  String? localPath;

  String? md5;
  SyncStatus status;
  String? remotePath;

  /// Cached local thumbnail saved before the original is deleted to free space,
  /// so the gallery can still show it. Null for non-visual or not-yet-freed.
  String? thumbPath;

  /// Cloud Vision category labels (e.g. "Beach", "Food"). Decoded lazily from
  /// the stored JSON on first access — avoids 96k jsonDecode calls on bulk load.
  List<String>? _labels;
  String? _labelsRaw;
  List<String> get labels => _labels ??= (_labelsRaw == null
      ? <String>[]
      : (jsonDecode(_labelsRaw!) as List).cast<String>());
  set labels(List<String> v) {
    _labels = v;
    _labelsRaw = null;
  }

  /// Whether Vision (labels + face boxes) has run for this asset.
  bool visionDone;

  /// Whether on-device face embeddings have been computed.
  bool facesDone;

  /// False if our app can't actually read this item's bytes — chiefly files in
  /// a cloned-app space (/storage/emulated/999/, e.g. App-Clone WhatsApp), which
  /// Android forbids third-party apps from reading. Such items can't be shown or
  /// backed up; the UI flags them "Cloned app — can't access".
  bool accessible;

  bool get isSafeInCloud =>
      status == SyncStatus.uploaded || status == SyncStatus.deletedLocal;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'is_video': isVideo ? 1 : 0,
        'kind': kind.name,
        'size': size,
        'created_at': createdAt.millisecondsSinceEpoch,
        'local_path': localPath,
        'md5': md5,
        'status': status.name,
        'remote_path': remotePath,
        'thumb_path': thumbPath,
        'labels': jsonEncode(labels),
        'vision_done': visionDone ? 1 : 0,
        'faces_done': facesDone ? 1 : 0,
        'accessible': accessible ? 1 : 0,
      };

  factory MediaAsset.fromMap(Map<String, Object?> m) {
    final a = MediaAsset(
      id: m['id'] as String,
      name: m['name'] as String,
      kind: m['kind'] != null
          ? kindFromName(m['kind'] as String)
          : ((m['is_video'] as int? ?? 0) == 1
              ? MediaKind.video
              : MediaKind.image),
      size: m['size'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      localPath: m['local_path'] as String?,
      md5: m['md5'] as String?,
      status: SyncStatus.values.byName(m['status'] as String),
      remotePath: m['remote_path'] as String?,
      thumbPath: m['thumb_path'] as String?,
      visionDone: (m['vision_done'] as int? ?? 0) == 1,
      facesDone: (m['faces_done'] as int? ?? 0) == 1,
      accessible: (m['accessible'] as int? ?? 1) == 1,
    );
    a._labelsRaw = m['labels'] as String?; // decoded lazily on first access
    return a;
  }
}

/// A detected face: bounding box + on-device embedding + assigned person.
class FaceRecord {
  FaceRecord({
    this.id,
    required this.assetId,
    required this.box,
    required this.embedding,
    this.personId,
  });

  int? id;
  final String assetId;

  /// [left, top, width, height] in image pixels.
  final List<double> box;

  /// L2-normalized embedding vector (e.g. 192 floats for MobileFaceNet).
  final List<double> embedding;

  /// Cluster/person assignment, null until clustering runs.
  int? personId;

  Map<String, Object?> toMap() => {
        'id': id,
        'asset_id': assetId,
        'box': jsonEncode(box),
        'embedding': jsonEncode(embedding),
        'person_id': personId,
      };

  factory FaceRecord.fromMap(Map<String, Object?> m) => FaceRecord(
        id: m['id'] as int?,
        assetId: m['asset_id'] as String,
        box: (jsonDecode(m['box'] as String) as List)
            .map((e) => (e as num).toDouble())
            .toList(),
        embedding: (jsonDecode(m['embedding'] as String) as List)
            .map((e) => (e as num).toDouble())
            .toList(),
        personId: m['person_id'] as int?,
      );
}

/// A cluster of faces the user can name ("Mom", "Aarav").
class Person {
  Person({this.id, this.label, this.coverFaceId});

  int? id;
  String? label;
  int? coverFaceId;

  Map<String, Object?> toMap() => {
        'id': id,
        'label': label,
        'cover_face_id': coverFaceId,
      };

  factory Person.fromMap(Map<String, Object?> m) => Person(
        id: m['id'] as int?,
        label: m['label'] as String?,
        coverFaceId: m['cover_face_id'] as int?,
      );
}

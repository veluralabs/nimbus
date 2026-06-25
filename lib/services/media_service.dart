import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:native_exif/native_exif.dart' as exif_reader;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/media_asset.dart';

/// Capture metadata for a photo/video: date/time + GPS + reverse-geocoded place.
class AssetMeta {
  AssetMeta({required this.date, this.lat, this.lng, this.place});
  final DateTime date;
  final double? lat;
  final double? lng;
  final String? place;
  bool get hasLocation => lat != null && lng != null;
}

/// Wraps photo_manager (MediaStore) to enumerate device photos/videos and
/// fetch thumbnails/files on demand. This is the correct API for a gallery —
/// it reads the media index instead of brute-force scanning the filesystem.
class MediaService {
  /// Requests photo/video access. On Android 13+ this is scoped media access;
  /// returns true for full or limited ("selected photos") authorization.
  Future<bool> requestAccess() async {
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.isAuth || ps.hasAccess;
  }

  /// Enumerates all images + videos + audio from MediaStore (no file I/O yet).
  /// Documents are handled separately by [DocumentScanner].
  Future<List<MediaAsset>> listAll() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.all, // images + videos + audio
      onlyAll: true, // the synthetic "Recent/All" album
    );
    if (paths.isEmpty) return [];

    final all = paths.first;
    final total = await all.assetCountAsync;
    final List<MediaAsset> out = [];
    const page = 200;

    for (int offset = 0; offset < total; offset += page) {
      final batch = await all.getAssetListRange(
        start: offset,
        end: (offset + page).clamp(0, total),
      );
      for (final e in batch) {
        out.add(MediaAsset(
          id: e.id,
          name: e.title ?? e.id,
          kind: switch (e.type) {
            AssetType.video => MediaKind.video,
            AssetType.audio => MediaKind.audio,
            _ => MediaKind.image,
          },
          size: 0, // filled when the file is resolved before upload
          createdAt: e.createDateTime,
        ));
      }
    }
    return out;
  }

  /// Saves a JPEG thumbnail to private app storage and returns its path, so the
  /// gallery can still show an item after its original is deleted to free space.
  /// Only meaningful for images/videos; returns null otherwise or on failure.
  Future<String?> cacheThumb(MediaAsset asset) async {
    if (asset.kind != MediaKind.image && asset.kind != MediaKind.video) {
      return null;
    }
    final bytes = await thumbnail(asset.id, px: 512);
    if (bytes == null) return null;
    final dir = Directory(p.join(
        (await getApplicationDocumentsDirectory()).path, 'thumbs'));
    await dir.create(recursive: true);
    final safe = asset.id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final file = File(p.join(dir.path, '$safe.jpg'));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// Returns the underlying [AssetEntity] for an id, or null if it's gone.
  Future<AssetEntity?> entity(String id) => AssetEntity.fromId(id);

  // In-memory thumbnail cache so the grid doesn't re-decode tiles on every
  // rebuild (the #1 source of scroll/rebuild jank). Simple LRU by insertion.
  static final _thumbCache = <String, Uint8List>{};
  static const _thumbCacheMax = 250;

  /// Synchronous cache hit, if present — lets the UI render instantly without
  /// a FutureBuilder flash on rebuild.
  static Uint8List? cachedThumb(String id, {int px = 200}) =>
      _thumbCache['$id@$px'];

  /// True if the bytes begin with the JPEG SOI marker (FF D8 FF). Used to reject
  /// the HEIC/AVIF bytes some devices return from a JPEG thumbnail request, which
  /// Image.memory can't decode (the blank-tile bug).
  static bool _looksJpeg(Uint8List? b) =>
      b != null &&
      b.length > 3 &&
      b[0] == 0xFF &&
      b[1] == 0xD8 &&
      b[2] == 0xFF;

  /// A small JPEG thumbnail for grid display (memory-cached). If the native
  /// thumbnailer fails (some HEIC/large/odd-codec images return null), it falls
  /// back to decoding the original and resizing — so a valid image always gets
  /// a thumbnail.
  Future<Uint8List?> thumbnail(String id, {int px = 200}) async {
    final key = '$id@$px';
    final hit = _thumbCache[key];
    if (hit != null) return hit;

    // AssetEntity.fromId hits a MediaStore cursor that can transiently fail
    // ("CursorWindow NO_MEMORY") under memory pressure — retry briefly.
    AssetEntity? e = await AssetEntity.fromId(id);
    if (e == null) {
      await Future.delayed(const Duration(milliseconds: 120));
      e = await AssetEntity.fromId(id);
    }
    if (e == null) return null;

    // Force JPEG output — on some devices the default returns HEIC/AVIF bytes
    // that Flutter's Image.memory can't decode (black/placeholder tiles).
    Uint8List? b = await e.thumbnailDataWithSize(
      ThumbnailSize.square(px),
      format: ThumbnailFormat.jpeg,
      quality: 88,
    );
    if (b == null) {
      await Future.delayed(const Duration(milliseconds: 120));
      b = await e.thumbnailDataWithSize(ThumbnailSize.square(px),
          format: ThumbnailFormat.jpeg, quality: 88);
    }
    // Crucial: some devices hand back NON-NULL but undecodable bytes here (still
    // HEIC/AVIF despite the JPEG request), so Image.memory silently fails to a
    // placeholder even though the file is perfectly readable (the full-screen
    // viewer works via originBytes). Treat "not a real JPEG" the same as null
    // and re-encode from the actual file/origin bytes, which always decodes.
    if (b == null || !_looksJpeg(b)) {
      // Fallback A: native compressor re-encodes the original from its path.
      try {
        final file = await e.file;
        if (file != null) {
          final c = await FlutterImageCompress.compressWithFile(
            file.path,
            minWidth: px * 2,
            minHeight: px * 2,
            quality: 85,
            format: CompressFormat.jpeg,
          );
          if (c != null && _looksJpeg(c)) b = c;
        }
      } catch (_) {/* try origin bytes next */}
    }
    if (b == null || !_looksJpeg(b)) {
      // Fallback B: the exact path the viewer uses — raw original bytes — then
      // downscale them. Covers images where e.file is null but originBytes work.
      try {
        final raw = await e.originBytes;
        if (raw != null) {
          final c = await FlutterImageCompress.compressWithList(
            raw,
            minWidth: px * 2,
            minHeight: px * 2,
            quality: 85,
            format: CompressFormat.jpeg,
          );
          if (_looksJpeg(c)) b = c;
        }
      } catch (_) {/* give up -> caller shows placeholder */}
    }
    if (b != null && _looksJpeg(b)) {
      if (_thumbCache.length >= _thumbCacheMax) {
        _thumbCache.remove(_thumbCache.keys.first);
      }
      _thumbCache[key] = b;
    }
    return b;
  }

  /// An aspect-correct, memory-bounded JPEG (native-decoded, never a full-res
  /// Dart bitmap) plus the scale factor from original pixels. Used by ML so we
  /// never blow up memory decoding 12–48MP originals.
  Future<({Uint8List bytes, double scale})?> proportionalImage(
      String id, int maxEdge) async {
    final e = await AssetEntity.fromId(id);
    if (e == null) return null;
    final w = e.width, h = e.height;
    if (w == 0 || h == 0) {
      final b = await e.thumbnailDataWithSize(ThumbnailSize.square(maxEdge),
          format: ThumbnailFormat.jpeg);
      return b == null ? null : (bytes: b, scale: 1.0);
    }
    final longEdge = w > h ? w : h;
    final target = longEdge < maxEdge ? longEdge : maxEdge;
    final s = target / longEdge;
    final b = await e.thumbnailDataWithSize(
        ThumbnailSize((w * s).round(), (h * s).round()),
        format: ThumbnailFormat.jpeg);
    return b == null ? null : (bytes: b, scale: s);
  }

  /// Reads capture date/time + GPS for an asset and reverse-geocodes the place.
  /// Location only exists for geotagged photos (most screenshots/downloads have
  /// none). Uses the free on-device geocoder.
  Future<AssetMeta?> metadata(String id) async {
    final e = await AssetEntity.fromId(id);
    if (e == null) return null;
    double? lat, lng;
    try {
      final ll = await e.latlngAsync();
      final la = ll?.latitude ?? 0;
      final lo = ll?.longitude ?? 0;
      if (la != 0) lat = la;
      if (lo != 0) lng = lo;
    } catch (_) {}
    // Fallback: read GPS straight from the original file's EXIF (needs
    // ACCESS_MEDIA_LOCATION). This catches photos MediaStore redacts.
    if (lat == null || lng == null) {
      try {
        final f = await e.file;
        if (f != null) {
          final exif = await exif_reader.Exif.fromPath(f.path);
          final coords = await exif.getLatLong();
          await exif.close();
          if (coords != null && coords.latitude != 0 && coords.longitude != 0) {
            lat = coords.latitude;
            lng = coords.longitude;
          }
        }
      } catch (_) {}
    }
    String? place;
    if (lat != null && lng != null) {
      try {
        final marks = await geo.placemarkFromCoordinates(lat, lng);
        if (marks.isNotEmpty) {
          final m = marks.first;
          place = [m.locality, m.administrativeArea, m.country]
              .where((s) => s != null && s.isNotEmpty)
              .join(', ');
        }
      } catch (_) {}
    }
    return AssetMeta(date: e.createDateTime, lat: lat, lng: lng, place: place);
  }

  /// Deletes assets from the device via MediaStore. On Android 11+ this raises
  /// the system delete-confirmation dialog. Returns true if all were removed.
  Future<bool> deleteAssets(List<String> ids) async {
    final removed = await PhotoManager.editor.deleteWithIds(ids);
    return removed.length == ids.length;
  }
}

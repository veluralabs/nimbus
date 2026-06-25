import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/media_asset.dart';

/// Scans the filesystem (using the all-files permission) for items MediaStore
/// doesn't surface: documents, archives, and the WhatsApp media folder. Each
/// becomes a `file:`-id MediaAsset handled directly via its path.
class DocumentScanner {
  static const _docExt = {
    // office
    '.pdf', '.doc', '.docx', '.docm', '.dot', '.dotx',
    '.xls', '.xlsx', '.xlsm', '.xlsb', '.csv', '.tsv',
    '.ppt', '.pptx', '.pptm', '.pps', '.ppsx',
    // open document
    '.odt', '.ods', '.odp', '.odg',
    // apple iwork
    '.pages', '.numbers', '.key',
    // text / markup / data
    '.txt', '.rtf', '.md', '.log', '.json', '.xml', '.yaml', '.yml',
    '.html', '.htm', '.tex', '.vcf', '.ics',
    // ebooks
    '.epub', '.mobi', '.azw', '.azw3', '.fb2', '.djvu',
    // archives
    '.zip', '.rar', '.7z', '.tar', '.gz', '.apk',
  };
  static const _audioExt = {'.mp3', '.m4a', '.aac', '.wav', '.ogg', '.opus', '.flac'};
  static const _videoExt = {'.mp4', '.mkv', '.3gp', '.mov', '.webm'};
  static const _imageExt = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic'};

  /// Folders that hold documents (not reliably in MediaStore).
  static const _docRoots = [
    '/storage/emulated/0/Documents',
    '/storage/emulated/0/Download',
  ];

  /// WhatsApp media lives here on Android 11+. Backing this up is the no-root
  /// path to "WhatsApp backup" (media only; the chat DB is encrypted).
  static const _whatsappRoot =
      '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp/Media';

  Future<List<MediaAsset>> scan() async {
    final out = <MediaAsset>[];
    // Documents/Download: documents + archives only (media there is in MediaStore).
    for (final root in _docRoots) {
      await _walk(Directory(root), out, docsOnly: true);
    }
    // WhatsApp: every kind, since MediaStore often misses /Android/media.
    await _walk(Directory(_whatsappRoot), out, docsOnly: false);
    return out;
  }

  Future<void> _walk(Directory dir, List<MediaAsset> out,
      {required bool docsOnly}) async {
    if (!await dir.exists()) return;
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        await _walk(e, out, docsOnly: docsOnly);
      } else if (e is File) {
        final ext = p.extension(name).toLowerCase();
        final kind = _kindFor(ext);
        if (kind == null) continue;
        if (docsOnly && kind != MediaKind.document) continue;
        int size;
        DateTime modified;
        try {
          final stat = e.statSync();
          size = stat.size;
          modified = stat.modified;
        } on FileSystemException {
          continue;
        }
        if (size == 0) continue;
        out.add(MediaAsset(
          id: 'file:${e.path}',
          name: name,
          kind: kind,
          size: size,
          createdAt: modified,
          localPath: e.path,
        ));
      }
    }
  }

  MediaKind? _kindFor(String ext) {
    if (_docExt.contains(ext)) return MediaKind.document;
    if (_audioExt.contains(ext)) return MediaKind.audio;
    if (_videoExt.contains(ext)) return MediaKind.video;
    if (_imageExt.contains(ext)) return MediaKind.image;
    return null;
  }
}

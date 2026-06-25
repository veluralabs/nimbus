import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:googleapis/storage/v1.dart' as gcs;
import 'package:googleapis_auth/auth_io.dart';

import '../config.dart';

/// Thin authenticated wrapper over the GCS JSON API: upload a file (streamed)
/// and delete an object. Auth uses the bundled service-account key.
class GcsClient {
  gcs.StorageApi? _api;
  AutoRefreshingAuthClient? _client;

  bool get isReady => _api != null;

  Future<void> init() async {
    if (isReady) return;
    String raw;
    try {
      raw = await rootBundle.loadString(Config.serviceAccountAsset);
    } catch (_) {
      throw StateError(
          'No service-account key found. Copy assets/service_account.json.example '
          'to assets/service_account.json and paste your GCS key (see README Setup).');
    }
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    if ((json['private_key'] as String?)?.contains('REPLACE_ME') ?? true) {
      throw StateError(
          'Service-account key is still a placeholder. Paste your real GCS key '
          'into assets/service_account.json (see README Setup).');
    }
    if (Config.bucketName.startsWith('REPLACE')) {
      throw StateError('Bucket name is still a placeholder.');
    }
    final creds = ServiceAccountCredentials.fromJson(json);
    _client = await clientViaServiceAccount(
      creds,
      const [gcs.StorageApi.devstorageReadWriteScope],
    );
    _api = gcs.StorageApi(_client!);
  }

  void dispose() {
    _client?.close();
    _client = null;
    _api = null;
  }

  /// base64 MD5 of a file, streamed (no full read into memory).
  static Future<String> md5Base64(File file) async {
    late Digest digest;
    final sink = ChunkedConversionSink<Digest>.withCallback(
      (acc) => digest = acc.single,
    );
    final input = md5.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return base64.encode(digest.bytes);
  }

  /// Uploads [file] to [objectName]; returns the md5Hash GCS computed.
  Future<String?> upload(File file, String objectName) async {
    final length = await file.length();
    final media = gcs.Media(file.openRead(), length);
    final obj = gcs.Object()..name = objectName;
    final res = await _api!.objects
        .insert(obj, Config.bucketName, uploadMedia: media);
    return res.md5Hash;
  }

  Future<void> delete(String objectName) async {
    await _api!.objects.delete(Config.bucketName, objectName);
  }

  /// Uploads raw bytes to [objectName] (used for the DB backup).
  Future<void> uploadBytes(String objectName, List<int> bytes) async {
    final media = gcs.Media(Stream.value(bytes), bytes.length);
    final obj = gcs.Object()..name = objectName;
    await _api!.objects.insert(obj, Config.bucketName, uploadMedia: media);
  }

  /// Lists objects under [prefix] with their sizes (for the cloud browser).
  Future<List<({String name, int size})>> listObjects(String prefix) async {
    final out = <({String name, int size})>[];
    String? token;
    do {
      final res = await _api!.objects.list(Config.bucketName,
          prefix: prefix, pageToken: token, maxResults: 1000);
      for (final o in res.items ?? const <gcs.Object>[]) {
        if (o.name != null) {
          out.add((name: o.name!, size: int.tryParse(o.size ?? '0') ?? 0));
        }
      }
      token = res.nextPageToken;
    } while (token != null);
    return out;
  }

  /// Lists all object names under [prefix] (paginated). Used to reconcile local
  /// backup state with the cloud after a reinstall.
  Future<List<String>> listObjectNames(String prefix) async {
    final out = <String>[];
    String? token;
    do {
      final res = await _api!.objects.list(
        Config.bucketName,
        prefix: prefix,
        pageToken: token,
        maxResults: 1000,
      );
      for (final o in res.items ?? const <gcs.Object>[]) {
        if (o.name != null) out.add(o.name!);
      }
      token = res.nextPageToken;
    } while (token != null);
    return out;
  }

  /// Downloads an object's bytes (used to view an original that was deleted
  /// locally to free space).
  Future<List<int>> download(String objectName) async {
    final media = await _api!.objects.get(
      Config.bucketName,
      objectName,
      downloadOptions: gcs.DownloadOptions.fullMedia,
    ) as gcs.Media;
    final out = <int>[];
    await for (final chunk in media.stream) {
      out.addAll(chunk);
    }
    return out;
  }
}

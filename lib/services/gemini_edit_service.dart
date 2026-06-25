import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:googleapis_auth/auth_io.dart';

import '../config.dart';

/// AI photo editing via Vertex AI's Gemini image model ("Nano Banana").
/// Send a photo + a natural-language instruction ("remove the background",
/// "make it golden hour") and get an edited image back. The original is never
/// modified — the caller saves the result as a separate version.
class GeminiEditService {
  // Newest Vertex AI image model (better quality/latency); falls back to 2.5.
  static const _models = ['gemini-3.1-flash-image', 'gemini-2.5-flash-image'];
  static const _location = 'global';

  AutoRefreshingAuthClient? _client;
  String? _projectId;

  Future<void> _init() async {
    if (_client != null) return;
    final raw = await rootBundle.loadString(Config.serviceAccountAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _projectId = json['project_id'] as String;
    final creds = ServiceAccountCredentials.fromJson(json);
    _client = await clientViaServiceAccount(
      creds,
      const ['https://www.googleapis.com/auth/cloud-platform'],
    );
  }

  void dispose() {
    _client?.close();
    _client = null;
  }

  /// Returns the edited image bytes, or throws on failure. Tries the newest
  /// model first and falls back to the prior one if it's unavailable.
  Future<Uint8List> edit(File image, String prompt) async {
    await _init();
    final b64 = base64.encode(await image.readAsBytes());
    final payload = jsonEncode({
      'contents': [
        {
          'role': 'user',
          'parts': [
            {
              'inlineData': {'mimeType': 'image/jpeg', 'data': b64}
            },
            {'text': prompt},
          ],
        }
      ],
      'generationConfig': {
        'responseModalities': ['IMAGE'],
      },
    });

    Object? lastError;
    for (final model in _models) {
      final url = Uri.parse(
        'https://aiplatform.googleapis.com/v1/projects/$_projectId/locations/$_location'
        '/publishers/google/models/$model:generateContent',
      );
      final res = await _client!.post(url,
          headers: {'Content-Type': 'application/json'}, body: payload);
      if (res.statusCode == 404) {
        lastError = 'model $model unavailable';
        continue; // try fallback
      }
      if (res.statusCode != 200) {
        throw Exception(
            'Edit failed (${res.statusCode}): ${res.body.substring(0, res.body.length.clamp(0, 200))}');
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final parts = (body['candidates'] as List?)?.firstOrNull?['content']
          ?['parts'] as List?;
      if (parts == null) throw Exception('No content returned');
      for (final p in parts) {
        final data = p['inlineData']?['data'] as String?;
        if (data != null) return base64.decode(data);
      }
      throw Exception('Model returned no image — try a clearer instruction');
    }
    throw Exception('No image model available ($lastError)');
  }
}

extension _FirstOrNull on List {
  dynamic get firstOrNull => isEmpty ? null : first;
}

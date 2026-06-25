/// App configuration. Edit these before building — see README "Setup".
///
/// None of the values here are committed with real credentials. The app refuses
/// to run against the cloud until you replace the placeholders below and drop
/// your own service-account key into `assets/service_account.json`.
class Config {
  static const String appName = 'Nimbus';

  /// The GCS bucket files get uploaded to. Just the name, e.g. "my-phone-backup".
  /// Create it in GCP Console -> Cloud Storage -> Buckets.
  static const String bucketName = 'REPLACE_ME-your-bucket-name';

  /// Per-user object prefix. Each signed-in user's media lives under their own
  /// uid namespace so accounts don't see each other's content. NOTE: with the
  /// in-app shared key this is logical isolation, not a hard security boundary.
  static String userPrefix(String uid) => 'users/$uid/';

  /// Asset path to the bundled service-account key (see pubspec.yaml assets).
  /// Copy `assets/service_account.json.example` to this path and paste your key.
  static const String serviceAccountAsset = 'assets/service_account.json';

  /// File names/extensions to never touch (case-insensitive). Add your own.
  static const List<String> skipExtensions = <String>[
    '.tmp',
    '.crswap',
  ];

  /// Hard guard: refuse to delete anything unless this is true AND the user
  /// has toggled "delete after upload" in the UI. Belt and suspenders.
  static const bool deletionFeatureEnabled = true;
}

/// Firebase Auth config (provisioned on your GCP/Firebase project). The Web API
/// key is not a secret in the credential sense — it identifies the project for
/// the Identity Toolkit REST API; access is governed by your Auth settings.
/// Replace both with the values from your own Firebase project.
class FirebaseConfig {
  static const String apiKey = 'REPLACE_ME-firebase-web-api-key';
  static const String projectId = 'REPLACE_ME-firebase-project-id';
}

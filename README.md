<div align="center">

# ☁️ Nimbus

**Your photos. Your cloud. Your rules.**

An open-source, self-hosted photo & media backup app for **iOS & Android** —
built with Flutter. Back up everything to **your own Google Cloud Storage
bucket**, then optionally free local space with checksum-verified offload.
On-device face grouping, AI categories, and AI editing included. No subscription,
no middle-man, no one mining your library.

[![License: MIT](https://img.shields.io/badge/License-MIT-6A5CF2.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android-3DDC84.svg)
![Flutter](https://img.shields.io/badge/Flutter-3.41-02569B.svg)
[![Sponsor](https://img.shields.io/badge/♥-Sponsor-ff69b4.svg)](FUNDING.md)

</div>

---

## Why Nimbus?

"Storage full." Google Photos wants a subscription, iCloud wants a subscription,
and your gallery is held hostage. Nimbus is a DIY alternative: it uploads your
media to a **Cloud Storage bucket you own and pay Google directly for** (pennies
per GB), verifies each upload with an MD5 checksum, and only then — if you opt in
— deletes the local copy to reclaim space, keeping a thumbnail so the gallery
still looks complete. Tap any offloaded photo and the original streams back.

It's not a hosted service. You run it against your own GCP project, so your
library never touches anyone else's servers.

## Features

- **Verified backup + offload** — upload to GCS, verify MD5, then *optionally*
  free local space (keeps a thumbnail; streams the original back on tap).
  Deletion is off by default and double-guarded.
- **Timeline gallery** — date-grouped, pinch-to-zoom density, Hero transitions,
  multi-select, immersive full-screen viewer with share.
- **Files tab** — Photos / Videos / Audio / Documents folders (My-Files style)
  plus a live cloud-storage browser; documents open with the system app.
- **People** — fully **on-device** face grouping: ML Kit detection +
  MobileFaceNet (TFLite) embeddings + agglomerative clustering. Free, private,
  screenshots excluded. Name a cluster and it becomes a Person.
- **Categories** — Google-style curated taxonomy built from Cloud Vision labels
  (opt-in; uses your Vision API quota).
- **AI Edit** — Gemini image model via Vertex AI, with before/after compare.
  Saves a new copy and keeps the original.
- **Auth** — Firebase email/password; each user gets a private cloud namespace.
- **Power- & network-aware** — WiFi-only by default (mobile-data bypass toggle),
  pauses on low battery, daily background auto-backup (WorkManager +
  foreground service with a status-bar notification).
- **Survives reinstall** — the local index is backed up to your bucket and
  restored on a fresh install, and existing cloud objects are reconciled so you
  never re-upload your whole library.
- **Glassmorphic UI** — light & dark themes.

## Architecture

```
lib/
├── config.dart            # bucket name, Firebase project, feature flags
├── data/app_db.dart       # local SQLite index (assets, faces, persons, tombstones)
├── models/                # MediaAsset, FaceRecord, Person
├── services/
│   ├── gcs_client.dart        # Cloud Storage REST + service-account auth
│   ├── media_service.dart     # MediaStore enumeration, robust thumbnails
│   ├── upload_manager.dart    # verified upload pipeline
│   ├── ml_processor.dart      # orchestrates Vision + faces
│   ├── face_*.dart            # ML Kit detect + MobileFaceNet embed + cluster
│   ├── conditions.dart        # network/battery gating
│   ├── background_service.dart# foreground service + WorkManager cron
│   ├── db_sync.dart           # index backup/restore to the bucket
│   └── auth_service.dart      # Firebase Identity Toolkit (REST)
└── ui/                    # gallery, files, people, categories, settings,
                           # photo viewer, AI edit, glass/shimmer widgets
```

**Stack:** Flutter · Google Cloud Storage · Firebase Auth · Cloud Vision ·
Vertex AI (Gemini) · ML Kit · TFLite (MobileFaceNet) · sqflite · WorkManager.

> **Renderer note:** Impeller is disabled (Skia) in the manifest because the
> heavy `BackdropFilter` glass effects crash on some Mali/MediaTek GPUs. Leave it
> as-is unless you've tested Impeller on your target devices.

---

## Setup

You need a Google Cloud project. Everything below uses Google's free tier or
costs cents; **you pay Google directly** and nothing flows through the author.

### 0. Prerequisites
- [Flutter](https://docs.flutter.dev/get-started/install) **3.41+** (Dart 3.11+)
- **Android:** a device/emulator on **Android 8.0 (API 26)+**
- **iOS:** Xcode 15+, an Apple Developer signing identity, **iOS 13+**
- A Google Cloud project with billing enabled

### 1. Service-account key (Cloud Storage)
1. **GCP Console → Cloud Storage → Buckets →** create a bucket (note its name).
2. **IAM & Admin → Service Accounts →** create one, grant it **Storage Object
   Admin** *scoped to that bucket only*.
3. **Keys → Add Key → JSON →** download it.
4. Copy the template and paste your key over it:
   ```bash
   cp assets/service_account.json.example assets/service_account.json
   # then open assets/service_account.json and replace its contents with your key
   ```
   `assets/service_account.json` is git-ignored, so your real key is never
   committed.

### 2. Configure the app
Edit [`lib/config.dart`](lib/config.dart):
```dart
static const String bucketName = 'your-bucket-name';      // from step 1
// FirebaseConfig:
static const String apiKey    = 'your-firebase-web-api-key';
static const String projectId = 'your-firebase-project-id';
```

### 3. Firebase Auth (email/password)
1. Create/enable a [Firebase](https://console.firebase.google.com) project on the
   same GCP project.
2. **Authentication → Sign-in method →** enable **Email/Password**.
3. Put the **Web API key** and **Project ID** into `lib/config.dart` (step 2).

### 4. (Optional) Face grouping model
Drop a **MobileFaceNet** TFLite model at
`assets/models/mobilefacenet.tflite` (input 112×112×3, output 192-d). See
[`assets/models/README.md`](assets/models/README.md). Without it, faces are still
detected/counted; they just aren't grouped into People.

### 5. (Optional) Cloud Vision + Vertex AI
Enable the **Cloud Vision API** and **Vertex AI API** on your project to use
Categories and AI Edit. They authenticate with the same service-account key.

### 6. Build & run
```bash
flutter pub get
flutter run                 # debug on a connected Android/iOS device

# Android release APK:
flutter build apk --release

# iOS (set your signing Team in Xcode first: ios/Runner.xcworkspace):
flutter build ipa --release
```

> **iOS notes:** photo access uses Apple's scoped photo-library permission
> (usage strings are already in `Info.plist`), so the Android-only
> "All files access" doesn't apply. Set your bundle ID / signing Team in Xcode
> before building, and run `pod install` in `ios/` if Flutter doesn't do it for
> you.

---

## ⚠️ Security model — read this

This app bundles a **service-account key inside the APK**. That's what makes it
fully self-contained with no backend, but it has real trade-offs:

- **Anyone who extracts your APK / IPA can read the key** and access the bucket
  it's scoped to. Scope the service account to **one bucket, object-admin
  only** — never project-wide.
- Per-user namespacing (`users/<uid>/`) is **logical** isolation for your own
  convenience, **not** a hard security boundary.
- This is great for **personal / family use** where you control who installs the
  app. It is **not** a model for a public multi-tenant product.
- **Rotate the key** if your APK is ever distributed beyond people you trust.

If you need true per-user security, put a thin backend (e.g. Cloud Functions
issuing signed URLs) between the app and storage. PRs welcome.

---

## Roadmap / ideas

- Polish iOS parity (background-fetch tuning, App Store icon set)
- Signed-URL backend option for hardened multi-user setups
- Pluggable storage backends (S3, Backblaze B2, self-hosted MinIO)
- WhatsApp media backup helpers

## Contributing

Issues and PRs are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Support the project

Nimbus is free. If it helped you, see **[FUNDING.md](FUNDING.md)**:
- 🌍 International: https://wise.com/pay/business/ishitkaroli
- 🇮🇳 From India: https://razorpay.me/@veluralabs
- ⭐ Or just star the repo — it really helps.

## Author

**Dr Ishit Karoli** — *Ishit K.* · Founder, [Velura Labs](https://veluralabs.com)

Top-Rated Flutter / Next.js / AI engineer. Available for freelance & contract work:
- 💼 **Upwork:** https://www.upwork.com/freelancers/~01ed85f91d7486fc48
- 🏢 **Velura Labs:** https://veluralabs.com

## License

[MIT](LICENSE) © 2026 Dr Ishit Karoli (Velura Labs)

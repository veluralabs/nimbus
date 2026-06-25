# Contributing to Nimbus

Thanks for helping make Nimbus better! 🙌 This is a community, self-hosted
project — issues, ideas, and PRs are all welcome.

## Ground rules

- **Never commit secrets.** `assets/service_account.json`, real Firebase keys,
  keystores, and `local.properties` are git-ignored — keep it that way. If you
  think you committed a credential, rotate it immediately and tell us.
- Be kind and constructive. Assume good intent.

## Getting set up

1. Follow **Setup** in the [README](README.md) (you'll need your own GCP bucket,
   service-account key, and Firebase project to run end-to-end).
2. `flutter pub get`
3. `flutter analyze` and `flutter test` should pass before you push.

## Submitting changes

1. Fork and branch: `git checkout -b feat/short-description`.
2. Keep PRs focused; describe **what** and **why**, and include screenshots/GIFs
   for UI changes.
3. Match the existing code style (the repo uses `flutter_lints`); run
   `dart format .` and `flutter analyze` — zero new warnings.
4. Note the device(s) / Android & iOS versions you tested on.

## Good first areas

- iOS parity and polish
- Additional storage backends (S3, Backblaze B2, MinIO)
- Accessibility and localization
- Tests around the upload/offload pipeline

## Reporting bugs

Open an issue with: device + OS version, steps to reproduce, what you expected,
what happened, and logs (`flutter run` console / `adb logcat`) if you have them.

By contributing, you agree your contributions are licensed under the project's
[MIT License](LICENSE).

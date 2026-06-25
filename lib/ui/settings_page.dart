import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../data/app_db.dart';
import '../services/auth_service.dart';
import '../services/background_sync.dart';
import '../services/conditions.dart';
import '../services/gcs_client.dart';
import '../services/ml_processor.dart';
import '../services/sync_controller.dart';
import '../theme.dart';
import '../util.dart';
import 'duplicates_screen.dart';
import 'widgets/sheets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.auth,
    required this.theme,
    required this.sync,
    required this.ml,
  });

  final AuthService auth;
  final ThemeController theme;
  final SyncController sync;
  final MlProcessor ml;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
        children: [
          // Account card
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  (auth.user?.email.characters.first ?? '?').toUpperCase(),
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
              ),
              title: Text(auth.user?.email ?? 'Signed in'),
              subtitle: const Text('Your private library'),
            ),
          ),
          const SizedBox(height: 8),

          // Cloud storage used — measured from the actual bucket, not a local
          // estimate (which was wrong: it summed local row sizes incl. items
          // never really uploaded, and missed objects from other devices).
          _CloudUsageCard(uid: auth.user?.uid),
          const SizedBox(height: 8),

          _SectionTitle('Appearance'),
          ListenableBuilder(
            listenable: theme,
            builder: (_, child) => Card(
              child: RadioGroup<ThemeMode>(
                groupValue: theme.mode,
                onChanged: (v) => theme.set(v!),
                child: Column(
                  children: [
                    for (final m in ThemeMode.values)
                      RadioListTile<ThemeMode>(
                        value: m,
                        title: Text(switch (m) {
                          ThemeMode.system => 'System default',
                          ThemeMode.light => 'Light',
                          ThemeMode.dark => 'Dark',
                        }),
                        secondary: Icon(switch (m) {
                          ThemeMode.system => Icons.brightness_auto_rounded,
                          ThemeMode.light => Icons.light_mode_rounded,
                          ThemeMode.dark => Icons.dark_mode_rounded,
                        }),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          _SectionTitle('Permissions'),
          ListenableBuilder(
            listenable: sync,
            builder: (_, child) => Card(
              child: ListTile(
                leading: Icon(
                  sync.hasAllFilesAccess
                      ? Icons.verified_user_rounded
                      : Icons.folder_off_rounded,
                  color: sync.hasAllFilesAccess ? Colors.green : scheme.error,
                ),
                title: const Text('All files access'),
                subtitle: Text(sync.hasAllFilesAccess
                    ? 'Granted — can back up and delete any file'
                    : 'Needed to manage and delete files. Tap to grant.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: sync.ensureFileAccess,
              ),
            ),
          ),
          const SizedBox(height: 8),

          _SectionTitle('Storage'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.copy_all_rounded),
              title: const Text('Find & remove duplicates'),
              subtitle: const Text(
                  'Keep the highest-resolution copy of each photo, free the rest.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DuplicatesScreen()),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: sync,
            builder: (_, child) => Card(
              child: SwitchListTile(
                secondary: const Icon(Icons.copy_all_rounded),
                title: const Text('Hide cloned-app photos'),
                subtitle: const Text(
                    'Photos from App-Clone / Parallel apps (e.g. cloned WhatsApp) '
                    'live in a space Android won’t let this app read, so they can’t '
                    'be shown or backed up. On = hide them; off = show a '
                    '“can’t access” tile.'),
                value: sync.hideInaccessible,
                onChanged: sync.setHideInaccessible,
              ),
            ),
          ),
          const SizedBox(height: 8),

          _SectionTitle('AI analysis'),
          const Card(child: _CloudLabelsToggle()),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.restart_alt_rounded),
              title: const Text('Reset & re-analyze'),
              subtitle: const Text(
                  'Clear all categories and people, then re-run Analyze fresh. Backups are kept.'),
              onTap: () => _resetAnalysis(context, ml),
            ),
          ),
          const SizedBox(height: 8),

          _SectionTitle('Backup'),
          ListenableBuilder(
            listenable: sync,
            builder: (_, child) => Card(
              child: SwitchListTile(
                secondary: const Icon(Icons.auto_delete_outlined),
                title: const Text('Free up space after backup'),
                subtitle: const Text(
                    'Delete a photo from this device only after it is uploaded and checksum-verified. Off by default.'),
                value: sync.deleteAfterUpload,
                onChanged: sync.setDeleteAfter,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Card(child: _MobileDataToggle()),
          const SizedBox(height: 8),
          const Card(child: _AutoBackupToggle()),
          const SizedBox(height: 24),

          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
            onPressed: () => auth.signOut(),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

/// Shows real bucket usage (summed object sizes) and object count, fetched once.
class _CloudUsageCard extends StatefulWidget {
  const _CloudUsageCard({required this.uid});
  final String? uid;

  @override
  State<_CloudUsageCard> createState() => _CloudUsageCardState();
}

class _CloudUsageCardState extends State<_CloudUsageCard> {
  ({int bytes, int count})? _usage;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final uid = widget.uid;
    if (uid == null) {
      setState(() => _error = true);
      return;
    }
    final gcs = GcsClient();
    try {
      await gcs.init();
      final objs = await gcs.listObjects(Config.userPrefix(uid));
      var bytes = 0;
      for (final o in objs) {
        bytes += o.size;
      }
      if (mounted) setState(() => _usage = (bytes: bytes, count: objs.length));
    } catch (_) {
      if (mounted) setState(() => _error = true);
    } finally {
      gcs.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loading = _usage == null && !_error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient:
                    LinearGradient(colors: [scheme.primary, scheme.tertiary]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.cloud_rounded, color: Colors.white),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cloud storage used',
                      style: TextStyle(
                          color: scheme.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(
                    _error
                        ? '—'
                        : loading
                            ? 'Checking…'
                            : humanSize(_usage!.bytes),
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    _error
                        ? 'Couldn’t reach cloud'
                        : loading
                            ? 'in your bucket'
                            : '${_usage!.count} files in cloud',
                    style: TextStyle(
                        color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

  Future<void> _resetAnalysis(BuildContext context, MlProcessor ml) async {
    final ok = await confirmSheet(
      context,
      title: 'Clear & re-analyze everything?',
      message:
          'Wipes ALL analysis data (faces, people, categories) and re-detects '
          'from scratch with the latest algorithm. Your photos and backups are '
          'NOT affected.\n\nFaces re-run on-device (free); category labels use '
          'Cloud Vision only if you enabled it.',
      confirmLabel: 'Reset',
      icon: Icons.restart_alt_rounded,
    );
    if (!ok) return;
    // Full wipe (faces, embeddings, people, labels, done-flags) so a re-run
    // re-analyzes everything fresh with the latest detection/clustering.
    await AppDb.instance.resetAnalysisHard();
    ml.notifyChanged(); // refresh People + Categories from the cleared DB
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cleared. Go to People → Analyze to re-run.'),
      ));
    }
  }

/// Opt-in toggle for paid Cloud Vision category labeling. Faces (free, on-device)
/// always run automatically regardless of this.
class _CloudLabelsToggle extends StatefulWidget {
  const _CloudLabelsToggle();
  @override
  State<_CloudLabelsToggle> createState() => _CloudLabelsToggleState();
}

class _CloudLabelsToggleState extends State<_CloudLabelsToggle> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    MlProcessor.cloudLabelsEnabled().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.label_important_outline_rounded),
      title: const Text('Smart categories (Cloud Vision)'),
      subtitle: const Text(
          'Auto-sort photos by content. Uses paid Cloud Vision (~\$3 / 1,000 photos). '
          'Face grouping is always free & automatic.'),
      value: _on,
      onChanged: (v) {
        setState(() => _on = v);
        MlProcessor.setCloudLabels(v);
      },
    );
  }
}

/// Allow uploads on mobile data (default: WiFi only).
class _MobileDataToggle extends StatefulWidget {
  const _MobileDataToggle();
  @override
  State<_MobileDataToggle> createState() => _MobileDataToggleState();
}

class _MobileDataToggleState extends State<_MobileDataToggle> {
  bool _on = false;
  @override
  void initState() {
    super.initState();
    UploadConditions.allowMobile().then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.signal_cellular_alt_rounded),
      title: const Text('Upload on mobile data'),
      subtitle: const Text(
          'Off = WiFi only (recommended). On = also use mobile data, which may use your plan.'),
      value: _on,
      onChanged: (v) async {
        setState(() => _on = v);
        await UploadConditions.setAllowMobile(v);
      },
    );
  }
}

/// Daily automatic background backup (WorkManager, WiFi + battery aware).
class _AutoBackupToggle extends StatefulWidget {
  const _AutoBackupToggle();
  @override
  State<_AutoBackupToggle> createState() => _AutoBackupToggleState();
}

class _AutoBackupToggleState extends State<_AutoBackupToggle> {
  bool _on = false;
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _on = p.getBool(kAutoBackupPref) ?? false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.schedule_rounded),
      title: const Text('Daily auto-backup'),
      subtitle: const Text(
          'Backs up new photos once a day in the background — only on WiFi and when the battery is fine.'),
      value: _on,
      onChanged: (v) async {
        setState(() => _on = v);
        final p = await SharedPreferences.getInstance();
        await p.setBool(kAutoBackupPref, v);
        if (v) {
          await enableDailyBackup(
            allowMobile: await UploadConditions.allowMobile(),
            deleteAfter: p.getBool('delete_after_upload') ?? false,
          );
        } else {
          await disableDailyBackup();
        }
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        child: Text(text,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            )),
      );
}

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/db_sync.dart';
import '../services/ml_processor.dart';
import '../services/sync_controller.dart';
import '../theme.dart';
import 'categories_page.dart';
import 'files_page.dart';
import 'gallery_page.dart';
import 'people_page.dart';
import 'settings_page.dart';
import 'widgets/glass.dart';

/// Signed-in shell: an aurora gradient backdrop with the active page over it and
/// a floating frosted-glass navigation pill.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.auth, required this.theme});
  final AuthService auth;
  final ThemeController theme;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final SyncController _sync;
  final _ml = MlProcessor();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _sync = SyncController(uid: widget.auth.user!.uid);
    _restoreThenLoad();
  }

  /// On a fresh install (just signed in), pull the cloud DB snapshot BEFORE the
  /// local DB is first opened, so all state comes back. Then load normally.
  Future<void> _restoreThenLoad() async {
    try {
      await DbSync.restoreIfFresh(widget.auth.user!.uid);
    } catch (_) {/* first use / offline */}
    await _sync.load();
  }

  @override
  void dispose() {
    _sync.dispose();
    _ml.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      GalleryPage(sync: _sync),
      FilesPage(uid: widget.auth.user!.uid),
      PeoplePage(ml: _ml),
      CategoriesPage(ml: _ml),
      SettingsPage(auth: widget.auth, theme: widget.theme, sync: _sync, ml: _ml),
    ];

    return AuroraBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: IndexedStack(index: _index, children: pages),
        bottomNavigationBar: _GlassNav(
          index: _index,
          onTap: (i) => setState(() => _index = i),
        ),
      ),
    );
  }
}

class _GlassNav extends StatelessWidget {
  const _GlassNav({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (Icons.photo_library_outlined, Icons.photo_library, 'Photos'),
    (Icons.folder_outlined, Icons.folder, 'Files'),
    (Icons.people_alt_outlined, Icons.people_alt, 'People'),
    (Icons.category_outlined, Icons.category, 'Categories'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Glass(
        radius: 30,
        blur: 30,
        opacity: 0.12,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            for (int i = 0; i < _items.length; i++)
              Expanded(
                child: _NavItem(
                  icon: index == i ? _items[i].$2 : _items[i].$1,
                  label: _items[i].$3,
                  selected: index == i,
                  onTap: () => onTap(i),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          gradient: selected ? NimbusTheme.brandGradient : null,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                color: selected ? Colors.white : Colors.white70, size: 24),
            if (selected) ...[
              const SizedBox(height: 3),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:workmanager/workmanager.dart';

import 'config.dart';
import 'services/auth_service.dart';
import 'services/background_service.dart';
import 'services/background_sync.dart';
import 'services/db_sync.dart';
import 'theme.dart';
import 'ui/home_shell.dart';
import 'ui/login_screen.dart';

final _auth = AuthService();
final _theme = ThemeController();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Hard-cap Flutter's image cache. With tens of thousands of thumbnails,
  // the default (~100MB / 1000 images) balloons native memory and gets the app
  // OOM-killed. 60MB / 200 images is plenty for a scrolling grid.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 60 << 20;
  PaintingBinding.instance.imageCache.maximumSize = 200;
  FlutterForegroundTask.initCommunicationPort();
  initBackgroundService();
  await Workmanager().initialize(backgroundDispatcher);
  await Future.wait([_auth.restore(), _theme.restore()]);
  // On a fresh install, restore the local index from the cloud BEFORE the DB is
  // opened, so reinstalling recovers backup + analysis state instantly.
  final uid = _auth.user?.uid;
  if (uid != null) {
    try {
      await DbSync.restoreIfFresh(uid);
    } catch (_) {/* first use / offline */}
  }
  runApp(const NimbusApp());
}

class NimbusApp extends StatelessWidget {
  const NimbusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _theme,
      builder: (context, _) {
        _theme.applySystemChrome(MediaQuery.platformBrightnessOf(context));
        return MaterialApp(
          title: Config.appName,
          debugShowCheckedModeBanner: false,
          theme: NimbusTheme.light,
          darkTheme: NimbusTheme.dark,
          themeMode: _theme.mode,
          home: const _AuthGate(),
        );
      },
    );
  }
}

/// Swaps between the login screen and the app based on auth state.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _auth,
      builder: (context, _) {
        if (!_auth.isSignedIn) {
          return LoginScreen(auth: _auth);
        }
        return HomeShell(auth: _auth, theme: _theme);
      },
    );
  }
}

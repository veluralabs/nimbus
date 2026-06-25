import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Gates uploads on network type + battery: WiFi-only by default (bypassable),
/// and paused on low battery unless charging.
class UploadConditions {
  static const _allowMobileKey = 'allow_mobile_upload';
  static const _lowBattery = 20;

  static Future<bool> allowMobile() async =>
      (await SharedPreferences.getInstance()).getBool(_allowMobileKey) ?? false;

  static Future<void> setAllowMobile(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_allowMobileKey, v);

  /// Whether uploads may proceed right now, plus a human reason if not.
  static Future<({bool ok, String reason})> check() async {
    final conn = await Connectivity().checkConnectivity();
    final onWifi = conn.contains(ConnectivityResult.wifi) ||
        conn.contains(ConnectivityResult.ethernet);
    final hasNet = !conn.contains(ConnectivityResult.none) && conn.isNotEmpty;

    if (!hasNet) return (ok: false, reason: 'Waiting for a network');
    if (!onWifi && !await allowMobile()) {
      return (ok: false, reason: 'Paused — on mobile data (WiFi only)');
    }

    final battery = Battery();
    final state = await battery.batteryState;
    final charging =
        state == BatteryState.charging || state == BatteryState.full;
    final level = await battery.batteryLevel;
    if (level <= _lowBattery && !charging) {
      return (ok: false, reason: 'Paused — low battery ($level%)');
    }
    return (ok: true, reason: '');
  }
}

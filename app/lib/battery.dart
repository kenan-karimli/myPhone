import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';

import 'store.dart';

/// {level: 0-100, charging: bool}, or null when this device has no battery.
Future<Map<String, dynamic>?> readBattery() async {
  try {
    if (Platform.isLinux) {
      final bat = Directory('/sys/class/power_supply').listSync().where((d) => d.path.split('/').last.startsWith('BAT')).firstOrNull;
      if (bat == null) return null;
      final level = int.parse(File('${bat.path}/capacity').readAsStringSync().trim());
      final status = File('${bat.path}/status').readAsStringSync().trim();
      return {'level': level, 'charging': status == 'Charging' || status == 'Full'};
    }
    if (Platform.isAndroid) {
      final b = Battery();
      final state = await b.batteryState;
      return {'level': await b.batteryLevel, 'charging': state == BatteryState.charging || state == BatteryState.full};
    }
  } catch (_) {}
  return null;
}

Timer? _timer;

/// Keeps store.myBattery fresh; it rides along with every hello.
Future<void> watchBattery(Store s) async {
  s.myBattery = await readBattery();
  _timer ??= Timer.periodic(const Duration(seconds: 30), (_) async => s.myBattery = await readBattery());
}

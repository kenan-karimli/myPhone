import 'dart:io';
import 'package:flutter/widgets.dart' show Size;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core.dart';

/// Desktop: closing the window hides it to the tray, so messages and
/// notifications keep working. Quit from the tray menu.
Future<void> initDesktop(List<String> args) async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setMinimumSize(const Size(800, 560));
  final d = _Desk();
  windowManager.addListener(d);
  trayManager.addListener(d);
  try {
    await trayManager.setIcon('assets/tray.png');
    await trayManager.setToolTip('myPhone');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Open myPhone'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  } catch (_) {} // no tray host (bar without a tray): the app still runs, reopen it from the launcher
  appForeground = !args.contains('--hidden');
  showWindow = showDesktopWindow;
  await syncAutostart();
  await installFileManagerScript();
}

/// Files (Nautilus) right-click → Scripts → "Send via myPhone".
/// Rewritten on every start so it always points at this copy of the app.
Future<void> installFileManagerScript() async {
  final dir = Directory('${Platform.environment['HOME']}/.local/share/nautilus');
  if (!Platform.isLinux || !dir.existsSync()) return;
  final f = File('${dir.path}/scripts/Send via myPhone');
  await f.parent.create(recursive: true);
  await f.writeAsString(_script(Platform.resolvedExecutable));
  await Process.run('chmod', ['755', f.path]);
}

String _script(String app) => r'''#!/bin/sh
# Installed by myPhone. Right-click files → Scripts → Send via myPhone.
APP='__APP__'
if [ -n "$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS" ]; then
  list="$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS"
else
  list=""
  for f in "$@"; do case "$f" in /*) ;; *) f="$PWD/$f" ;; esac; list="$list$f
"; done
fi
[ -n "$list" ] || exit 0
send() { printf '%s
' "$list" | curl -sf --max-time 5 -H 'Content-Type: text/plain' --data-binary @- http://127.0.0.1:4747/share >/dev/null; }
send && exit 0
# Not running yet: start it in the tray, then hand the files over.
"$APP" --hidden >/dev/null 2>&1 &
i=0
while [ "$i" -lt 40 ]; do sleep 0.25; send && exit 0; i=$((i + 1)); done
notify-send myPhone "Couldn't start myPhone to send the files." 2>/dev/null
exit 1
'''.replaceFirst('__APP__', app.replaceAll("'", "'\\''"));

Future<void> showDesktopWindow() async {
  await windowManager.show();
  await windowManager.focus();
  appForeground = true;
}

Future<void> quitApp() async {
  await node?.stop();
  await trayManager.destroy();
  exit(0);
}

File get _autostartFile => File('${Platform.environment['HOME']}/.config/autostart/myphone.desktop');

/// "Start at login" (default on): an XDG autostart entry that launches hidden in the tray.
Future<void> syncAutostart() async {
  if (!Platform.isLinux) return;
  final f = _autostartFile;
  if (store.get('autostart', true)) {
    await f.parent.create(recursive: true);
    await f.writeAsString('[Desktop Entry]\nType=Application\nName=myPhone\nExec="${Platform.resolvedExecutable}" --hidden\nX-GNOME-Autostart-enabled=true\n');
  } else if (f.existsSync()) {
    await f.delete();
  }
}

class _Desk with WindowListener, TrayListener {
  @override
  void onWindowClose() async {
    if (store.get('keepRunning', true)) {
      await windowManager.hide();
      appForeground = false;
    } else {
      await quitApp();
    }
  }

  @override
  void onWindowFocus() {
    appForeground = true;
    if (visibleChat != null) setVisibleChat(visibleChat);
  }

  @override
  void onWindowBlur() => appForeground = false;

  @override
  void onTrayIconMouseDown() => showDesktopWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'open') showDesktopWindow();
    if (item.key == 'quit') quitApp();
  }
}

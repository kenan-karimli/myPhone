import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:phone_native/phone_native.dart';

import 'agents.dart';
import 'assistant.dart';
import 'battery.dart';
import 'clipboard.dart';
import 'mirror.dart';
import 'net.dart';
import 'screen.dart';
import 'store.dart';

late Store store;
late Client client;
Node? node; // in-app server (Linux, or Android with background off)

/// Which chat is on screen, and whether the app is in front; decides if we notify.
String? visibleChat;
String? visibleAgent; // agent session on screen (no alert for it)

/// PC only: Claude Code agents the phone can drive, and live screen view.
AgentHost? agentHost;
ScreenHost? screenHost;
MirrorHost? mirrorHost;
Assistant? assistant;

/// Agent notification taps ask the UI to open (device id, session id).
final openAgentRequests = StreamController<(String, String)>.broadcast();
bool appForeground = true;

/// Notification taps ask the UI to open a chat.
final openChatRequests = StreamController<String>.broadcast();

bool get isDesktop => Platform.isLinux || Platform.isWindows || Platform.isMacOS;

/// Files handed over by the desktop file manager ("Send via myPhone").
final shareRequests = StreamController<List<String>>.broadcast();

/// Set by desktop.dart: bring the window back from the tray.
Future<void> Function()? showWindow;

final _notes = FlutterLocalNotificationsPlugin();

Future<Directory> dataDir() async => Directory('${(await getApplicationSupportDirectory()).path}/myphone');

Future<Directory> saveDir() async {
  final custom = store.settings['saveDir'] as String?;
  if (custom != null && custom.isNotEmpty) return Directory(custom);
  if (Platform.isAndroid) {
    // shortcut: writes straight into shared Download/ (allowed for own files on Android 11+); use MediaStore if older Androids matter.
    const pub = '/storage/emulated/0/Download/myPhone';
    try {
      await Directory(pub).create(recursive: true);
      return Directory(pub);
    } catch (_) {
      return Directory('${(await getExternalStorageDirectory())!.path}/myPhone');
    }
  }
  Directory? dl;
  try {
    dl = await getDownloadsDirectory();
  } catch (_) {}
  return Directory('${(dl ?? Directory('${Platform.environment['HOME'] ?? '.'}/Downloads')).path}/myPhone');
}

bool get androidService => Platform.isAndroid && store.get('background', true);

Future<void> boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) FlutterForegroundTask.initCommunicationPort();
  store = await Store.open(await dataDir());
  await store.loadAllChats();
  client = Client(store);
  await watchBattery(store);
  store.onLowBattery = (id, b) {
    final d = store.devices[id];
    if (d != null) notifyLowBattery(store, d, b);
  };
  await initNotifications(foreground: true);
  await applyBackgroundMode();
  client.startSweeping();
  syncClipWatcher(store, client);

  if (Platform.isAndroid) {
    PhoneNative.onSendClip((t) {
      if (!androidService) sendClip(store, client, t, force: true); // otherwise the service sends it
    });
    FlutterForegroundTask.addTaskDataCallback((data) async {
      await store.reloadDevices();
      if (data is String && data.isNotEmpty) await store.loadChat(data);
    });
  }
  // Desktop tracks focus through window events instead (desktop.dart).
  if (!isDesktop) {
    AppLifecycleListener(onStateChange: (s) async {
      appForeground = s == AppLifecycleState.resumed;
      _tellService();
      if (appForeground && Platform.isAndroid) {
        await store.reloadDevices(); // pick up replies sent from notifications
        await store.loadAllChats();
        client.sweep();
      }
    });
  }
}

void setVisibleAgent(String? sid) {
  visibleAgent = sid;
  _tellService();
}

void setVisibleChat(String? id) {
  visibleChat = id;
  _tellService();
  if (id != null) {
    store.markRead(id);
    _notes.cancel(id: id.hashCode).catchError((_) {});
  }
}

void _tellService() {
  if (androidService) FlutterForegroundTask.sendDataToTask({'chat': visibleChat ?? '', 'agent': visibleAgent ?? '', 'fg': appForeground});
}

/// Android + background on: the server lives in a foreground service so messages
/// arrive with the app closed. Otherwise it runs inside the app.
Future<void> applyBackgroundMode() async {
  if (androidService) {
    await node?.stop();
    node = null;
    await _startService();
  } else {
    if (Platform.isAndroid && await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    if (node == null) {
      if (isDesktop) {
        agentHost ??= AgentHost(store, alert: (devId, ev) {
          final d = store.devices[devId];
          if (d != null) client.sendEvent(d, ev).catchError((_) {});
        });
      }
      if (isDesktop) screenHost ??= ScreenHost(store);
      if (isDesktop && assistant == null) {
        assistant = Assistant(store, agentHost!, client, await dataDir());
        assistant!.setup().catchError((_) {});
      }
      if (isDesktop && mirrorHost == null) {
        mirrorHost = MirrorHost(store);
        mirrorHost!.start().catchError((_) => mirrorHost = null);
      }
      node = Node(store, saveDir: saveDir, onShare: shareRequests.add, extraRoutes: !isDesktop ? null : (req, from) async => await agentHost!.handle(req, from) || await screenHost!.handle(req, from), localRoutes: assistant?.handleLocal, onIncoming: (d, m) {
        if (m != null) assistant?.onMessage(d, m);
        if (m != null && (!appForeground || visibleChat != d.id)) notify(store, d, m);
      }, onAgent: (d, ev) {
        if (ev['t'] == 'clip') {
          receiveClip(store, ev['text'] ?? '', force: ev['force'] == true);
        } else if (ev['t'] == 'ring') {
          ringHere(store, d);
        } else if (ev['t'] == 'mirror') {
          // In the app: ask for capture consent right away. Otherwise a notification to tap.
          appForeground ? startSharingTo(d, store.myId).catchError((_) => false) : notifyMirror(store, d);
        } else if (!(appForeground && visibleAgent == ev['sid'])) {
          notifyAgent(store, d, ev);
        }
      });
      try {
        await node!.start();
      } catch (e) {
        node = null; // port busy (service still shutting down) - next toggle retries
      }
    }
  }
}

Future<void> _startService() async {
  if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
  if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'myphone_service',
      channelName: 'Connection',
      channelDescription: 'Keeps myPhone reachable by your other devices.',
      channelImportance: NotificationChannelImportance.MIN,
      priority: NotificationPriority.MIN,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: true,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    serviceId: 4747,
    serviceTypes: [ForegroundServiceTypes.remoteMessaging],
    notificationTitle: 'myPhone online',
    notificationText: 'Your devices can reach this phone',
    callback: startCallback,
  );
}

@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(_NodeTask());

class _NodeTask extends TaskHandler {
  Node? _node;
  late Store _store;
  String _chat = '', _agent = '';
  bool _fg = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _store = await Store.open(await dataDir());
    store = _store; // saveDir() reads settings from the global
    await watchBattery(_store); // the phone's level goes out with every hello
    final c = Client(_store);
    PhoneNative.onSendClip((t) => sendClip(_store, c, t, force: true)); // Quick Settings tile
    await initNotifications(foreground: false);
    _node = Node(_store, saveDir: saveDir, onAgent: (d, ev) async {
      if (ev['t'] == 'clip') {
        await _store.reloadSettings(); // the switch lives in the UI isolate
        receiveClip(_store, ev['text'] ?? '', force: ev['force'] == true);
      } else if (ev['t'] == 'ring') {
        ringHere(_store, d);
      } else if (ev['t'] == 'mirror') {
        notifyMirror(_store, d); // the service can't show Android's consent dialog; the tap opens the app
      } else if (!(_fg && _agent == ev['sid'])) {
        notifyAgent(_store, d, ev);
      }
    }, onIncoming: (d, m) async {
      FlutterForegroundTask.sendDataToMain(d.id);
      if (m != null && !(_fg && _chat == d.id)) {
        await _store.reloadAll(); // fresh notification prefs
        notify(_store, d, m);
      }
    });
    await _node!.start();
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      _chat = data['chat'] ?? '';
      _agent = data['agent'] ?? '';
      _fg = data['fg'] == true;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async => _node?.stop();
}

// ---------- notifications ----------

Future<void> initNotifications({required bool foreground}) async {
  await _notes.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
    ),
    onDidReceiveNotificationResponse: foreground ? _onTap : null,
    onDidReceiveBackgroundNotificationResponse: onNotificationAction,
  );
}

Future<void> notify(Store s, Device d, Msg m) async {
  if (!s.get('notify', true)) return;
  final body = !s.get('preview', true) ? (m.kind == 'text' ? 'New message' : 'Sent you a file') : m.kind == 'text' ? m.text : '${m.kind == 'image' ? '📷' : '📎'} ${m.name} · ${fmtSize(m.size)}';
  await _notes.show(
    id: d.id.hashCode,
    title: d.name,
    body: body,
    payload: d.id,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails('myphone_msgs', 'Messages',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          actions: [
            AndroidNotificationAction('reply', 'Reply', inputs: [AndroidNotificationActionInput(label: 'Reply')], allowGeneratedReplies: true),
            AndroidNotificationAction('read', 'Mark as read'),
          ]),
      linux: LinuxNotificationDetails(
        icon: AssetsLinuxIcon('assets/avatars/${const {'phone', 'laptop', 'desktop', 'tablet'}.contains(d.kind) ? d.kind : 'desktop'}.png'),
        category: LinuxNotificationCategory.imReceived,
        defaultActionName: 'Open',
        actions: const [LinuxNotificationAction(key: 'read', label: 'Mark as read')],
      ),
    ),
  );
}

/// "Find my phone": loud alarm sound + a notification to stop it.
Future<void> ringHere(Store s, Device from) async {
  if (!Platform.isAndroid) return;
  await PhoneNative.ring();
  await _notes.show(
    id: 'ring'.hashCode,
    title: 'Ringing from ${from.name}',
    body: 'Tap to stop.',
    payload: 'ring',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails('myphone_ring', 'Find my phone',
          importance: Importance.max, priority: Priority.max, ongoing: true, autoCancel: true,
          actions: [AndroidNotificationAction('stop', 'Stop')]),
    ),
  );
}

Future<void> notifyMirror(Store s, Device pc) => _notes.show(
      id: 'mirror${pc.id}'.hashCode,
      title: '${pc.name} wants to see your screen',
      body: 'Tap to share your screen with ${pc.name}. Android will ask you to confirm.',
      payload: 'mirror|${pc.id}',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('myphone_mirror', 'Screen sharing requests', importance: Importance.high, priority: Priority.high),
      ),
    );

/// The app was opened by tapping a notification: act on it once the UI is up.
Future<void> handleLaunchNotification() async {
  final d = await _notes.getNotificationAppLaunchDetails();
  final r = d?.notificationResponse;
  if (d?.didNotificationLaunchApp == true && r != null) {
    await Future.delayed(const Duration(milliseconds: 600));
    await _onTap(r);
  }
}

Future<void> notifyLowBattery(Store s, Device d, Map b) async {
  if (!s.get('notify', true) || !s.get('batteryAlerts', true)) return;
  await _notes.show(
    id: 'battery${d.id}'.hashCode,
    title: '${d.name} battery low',
    body: '${b['level']}% left. Plug it in soon.',
    payload: d.id,
    notificationDetails: NotificationDetails(
      android: const AndroidNotificationDetails('myphone_battery', 'Battery'),
      linux: LinuxNotificationDetails(icon: AssetsLinuxIcon('assets/avatars/${const {'phone', 'laptop', 'desktop', 'tablet'}.contains(d.kind) ? d.kind : 'desktop'}.png')),
    ),
  );
}

/// "Claude needs approval" (with Allow / Deny) or "Claude finished".
Future<void> notifyAgent(Store s, Device pc, Map ev) async {
  if (!s.get('notify', true)) return;
  final approve = ev['kind'] == 'approve';
  await _notes.show(
    id: 'agent${ev['sid']}'.hashCode,
    title: approve ? 'Claude needs approval · ${pc.name}' : 'Claude finished · ${pc.name}',
    body: '${ev['title']}\n${ev['text']}',
    payload: 'agent|${pc.id}|${ev['sid']}|${ev['rid'] ?? ''}',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails('myphone_agents', 'Claude agents',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: const BigTextStyleInformation(''),
          actions: approve ? const [AndroidNotificationAction('deny', 'Deny'), AndroidNotificationAction('allow', 'Allow')] : null),
      linux: const LinuxNotificationDetails(defaultActionName: 'Open'),
    ),
  );
}

/// Handles taps/buttons on agent notifications. Returns false if [payload] isn't one.
Future<bool> _agentAction(String payload, String? action, Store s, Client c) async {
  if (!payload.startsWith('agent|')) return false;
  final p = payload.split('|');
  final pc = s.devices[p[1]];
  if (pc == null) return true;
  if (action == 'allow' || action == 'deny') {
    await c.call(pc, 'POST', '/agents/s/${p[2]}/approve', body: {'rid': p[3], 'allow': action == 'allow'}).catchError((_) => {});
  } else {
    openAgentRequests.add((p[1], p[2]));
  }
  return true;
}

Future<void> _onTap(NotificationResponse r) async {
  final id = r.payload;
  if (id == null) return;
  if (id == 'ring') {
    await PhoneNative.stopRing();
    await _notes.cancel(id: 'ring'.hashCode);
    return;
  }
  if (await _agentAction(id, r.actionId, store, client)) return;
  if (id.startsWith('mirror|')) {
    final pc = store.devices[id.split('|')[1]];
    if (pc != null) await startSharingTo(pc, store.myId).catchError((_) => false);
    return;
  }
  if (r.actionId == 'reply' && (r.input ?? '').trim().isNotEmpty) {
    _notes.cancel(id: id.hashCode).catchError((_) {});
    final d = store.devices[id];
    if (d != null) await client.sendText(d, r.input!.trim());
    await store.markRead(id);
  } else if (r.actionId == 'read') {
    await store.markRead(id);
  } else {
    await showWindow?.call();
    openChatRequests.add(id);
  }
}

/// Notification buttons on Android land here, in their own isolate.
@pragma('vm:entry-point')
Future<void> onNotificationAction(NotificationResponse r) async {
  final id = r.payload;
  if (id == null) return;
  DartPluginRegistrant.ensureInitialized();
  await _notes.cancel(id: id.hashCode).catchError((_) {}); // clears Android's "sending…" spinner
  if (id == 'ring') {
    await PhoneNative.stopRing(); // same process as the player, so this stops it
    return;
  }
  final s = await Store.open(await dataDir());
  if (id.startsWith('agent|')) {
    await _notes.cancel(id: 'agent${id.split('|')[2]}'.hashCode).catchError((_) {});
    final c = Client(s);
    await _agentAction(id, r.actionId, s, c);
    c.close();
    return;
  }
  await s.loadChat(id);
  if (r.actionId == 'reply' && (r.input ?? '').trim().isNotEmpty && s.devices[id] != null) {
    final c = Client(s);
    final m = await c.sendText(s.devices[id]!, r.input!.trim());
    for (var i = 0; i < 50 && m.status != 'sent'; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    c.close();
  }
  await s.markRead(id);
}

/// My own tailnet addresses, for the settings screen.
Future<List<String>> myTailnetIps() async {
  final out = <String>[];
  for (final i in await NetworkInterface.list()) {
    for (final a in i.addresses) {
      if (!a.isLoopback && allowedPeer(a)) out.add(a.address);
    }
  }
  return out;
}

String jsonPretty(Object o) => const JsonEncoder.withIndent('  ').convert(o);

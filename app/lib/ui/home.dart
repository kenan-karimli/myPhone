import 'dart:async';

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../clipboard.dart';
import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'add_device.dart';
import 'agents.dart';
import 'chat.dart';
import 'device_list.dart';
import 'info.dart';
import 'settings.dart';
import 'share_sheet.dart';
import 'widgets.dart';

/// Phone layout below 720 px wide, two-pane desktop layout above.
class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) => box.maxWidth >= 720 ? const DesktopShell() : const MobileHome());
}

Route<T> _route<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: Motion.d(380),
      reverseTransitionDuration: Motion.d(300),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, a, s, child) => SharedAxisTransition(animation: a, secondaryAnimation: s, transitionType: SharedAxisTransitionType.horizontal, fillColor: Colors.transparent, child: child),
    );

// ---------------- phone ----------------

class MobileHome extends StatefulWidget {
  const MobileHome({super.key});
  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  StreamSubscription? _sub, _agentSub;
  @override
  void initState() {
    super.initState();
    _sub = openChatRequests.stream.listen((id) {
      final d = store.devices[id];
      if (d != null && mounted) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        _open(d);
      }
    });
    _agentSub = openAgentRequests.stream.listen((r) {
      final pc = store.devices[r.$1];
      if (pc == null || !mounted) return;
      Navigator.of(context).popUntil((x) => x.isFirst);
      Navigator.of(context).push(agentRoute(AgentSessionPage(pc: pc, id: r.$2, title: 'Claude')));
    });
    listenForShares((paths, text) async {
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      final r = await showShareSheet(context, paths, text);
      if (r == null || !mounted) return;
      if (r.$2) {
        shareToClaude(context, r.$1, paths, text);
      } else {
        _open(r.$1);
      }
    }, onFocus: () => phoneClipOnResume(store, client)); // window focus = Android lets us read the clipboard
  }

  @override
  void dispose() {
    _sub?.cancel();
    _agentSub?.cancel();
    super.dispose();
  }

  void _open(Device d) => Navigator.of(context).push(_route(MobileChatPage(dev: d)));
  void _add() => Navigator.of(context).push(_route(const AddDevicePage()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 16, 24),
            child: Row(children: [
              Expanded(child: Text('myPhone', style: mpStyle(context, size: MpText.title, w: FontWeight.w700))),
              IconBtn('settings', iconSize: 22, color: MpColors.of(context).text2, onTap: () => Navigator.of(context).push(_route(Scaffold(body: SafeArea(child: SettingsView(onClose: () => Navigator.pop(context))))))),
              const SizedBox(width: 4),
              IconBtn('add', bg: MpColors.of(context).text, color: MpColors.of(context).bg, onTap: _add, tip: 'Add device'),
            ]),
          ),
          Expanded(child: StoreBuilder(builder: (context) => AnimatedSwitcher(
                duration: Motion.d(300),
                child: store.devices.isEmpty ? EmptyDevices(onAdd: _add) : DeviceList(onOpen: _open),
              ))),
        ]),
      ),
    );
  }
}

class MobileChatPage extends StatelessWidget {
  final Device dev;
  const MobileChatPage({super.key, required this.dev});
  @override
  Widget build(BuildContext context) => Scaffold(
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          bottom: false,
          child: ChatView(
            dev: dev,
            onBack: () => Navigator.pop(context),
            onInfo: () => showInfoSheet(context, dev, () => Navigator.pop(context)),
          ),
        ),
      );
}

// ---------------- desktop ----------------

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  String? _selected;
  bool _info = false, _settings = false;
  StreamSubscription? _sub, _shareSub;

  @override
  void initState() {
    super.initState();
    _sub = openChatRequests.stream.listen((id) => setState(() {
          _selected = id;
          _settings = false;
        }));
    _shareSub = shareRequests.stream.listen((paths) async {
      await showWindow?.call();
      if (!mounted) return;
      final d = await showShareSheet(context, paths, '', desktop: true);
      if (d != null && mounted) {
        setState(() {
          _selected = d.$1.id;
          _settings = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _shareSub?.cancel();
    super.dispose();
  }

  void _add() => showAddDeviceDialog(context, (d) {
        setState(() {
          _selected = d.id;
          _settings = false;
        });
        showToast(context, '${d.name} added');
      });

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    return Scaffold(
      body: StoreBuilder(builder: (context) {
        final dev = store.devices[_selected];
        final Widget main;
        if (_settings) {
          main = SettingsView(key: const ValueKey('settings'), desktop: true, onClose: () => setState(() => _settings = false));
        } else if (store.devices.isEmpty) {
          main = EmptyDevices(key: const ValueKey('empty'), desktop: true, onAdd: _add);
        } else if (dev == null) {
          main = Center(
            key: const ValueKey('none'),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              MpIcon('phone', size: 32, stroke: 1.4, color: c.text2),
              const SizedBox(height: 16),
              Text('Select a device', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('Pick a device on the left to see your messages and files.', style: mpStyle(context, color: c.text2)),
            ]),
          );
        } else {
          main = ChatView(key: ValueKey(dev.id), dev: dev, desktop: true, infoOpen: _info, onInfo: () => setState(() => _info = !_info));
        }
        final showInfo = _info && dev != null && !_settings;

        return Row(children: [
          // sidebar
          Container(
            width: 280,
            decoration: BoxDecoration(color: c.surface, border: Border(right: BorderSide(color: c.line))),
            child: Column(children: [
              SizedBox(
                height: 64,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
                  child: Row(children: [
                    Expanded(child: Text('myPhone', style: mpStyle(context, size: MpText.title, w: FontWeight.w700))),
                    IconBtn('add', size: 36, iconSize: 20, onTap: _add, tip: 'Add device'),
                  ]),
                ),
              ),
              Expanded(
                child: store.devices.isEmpty
                    ? Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 0), child: Text('Devices you add appear here.', style: mpStyle(context, size: MpText.meta, color: c.text2)))
                    : DeviceList(desktop: true, selected: _settings ? null : _selected, onOpen: (d) => setState(() {
                          _selected = d.id;
                          _settings = false;
                        })),
              ),
              Container(
                height: 56,
                padding: const EdgeInsets.fromLTRB(24, 0, 12, 0),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
                child: Row(children: [
                  MpIcon(store.myKind, size: 16, color: c.text2),
                  const SizedBox(width: 12),
                  Expanded(child: Text('${store.myName} · this device', maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: MpText.meta, color: c.text2))),
                  IconBtn('settings', size: 36, iconSize: 18, color: _settings ? c.text : c.text2, bg: _settings ? c.surface2 : null, onTap: () => setState(() => _settings = !_settings), tip: 'Settings'),
                ]),
              ),
            ]),
          ),
          // main pane
          Expanded(
            child: PageTransitionSwitcher(
              duration: Motion.d(380),
              // Same horizontal shared-axis slide the phone uses between screens.
              transitionBuilder: (child, a, s) => SharedAxisTransition(animation: a, secondaryAnimation: s, transitionType: SharedAxisTransitionType.horizontal, fillColor: c.bg, child: child),
              child: main,
            ),
          ),
          // info panel slides in (200 ms ease-out, per design); chat narrows to fit
          AnimatedContainer(
            duration: Motion.d(240),
            curve: Motion.curve,
            width: showInfo ? 320 : 0,
            decoration: BoxDecoration(color: c.surface, border: Border(left: BorderSide(color: showInfo ? c.line : Colors.transparent))),
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 320, maxWidth: 320,
                child: dev == null
                    ? const SizedBox()
                    : Column(children: [
                        Container(
                          height: 64,
                          padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
                          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
                          child: Row(children: [
                            Expanded(child: Text('Device info', style: mpStyle(context, w: FontWeight.w700))),
                            IconBtn('close', size: 36, iconSize: 20, onTap: () => setState(() => _info = false)),
                          ]),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: DeviceInfo(dev: dev, desktop: true, onRemoved: () => setState(() {
                                  _selected = null;
                                  _info = false;
                                })),
                          ),
                        ),
                      ]),
              ),
            ),
          ),
        ]);
      }),
    );
  }
}

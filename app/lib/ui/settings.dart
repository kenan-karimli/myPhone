import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core.dart';
import '../desktop.dart';
import '../clipboard.dart';
import '../mirror.dart';
import '../tokens.dart';
import 'widgets.dart';

class SettingsView extends StatefulWidget {
  final bool desktop;
  final VoidCallback onClose;
  const SettingsView({super.key, required this.onClose, this.desktop = false});
  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late final _name = TextEditingController(text: store.myName);
  List<String> _ips = [];
  String _saveDir = '';

  @override
  void initState() {
    super.initState();
    myTailnetIps().then((v) => mounted ? setState(() => _ips = v) : null);
    saveDir().then((d) => mounted ? setState(() => _saveDir = d.path) : null);
  }

  @override
  void dispose() {
    _saveName();
    _name.dispose();
    super.dispose();
  }

  void _saveName() {
    final n = _name.text.trim();
    if (n.isNotEmpty && n != store.myName) {
      store.set('name', n);
      client.sweep(); // peers learn the new name via hello
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    Widget card(List<Widget> rows) => Container(
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(MpRadius.bubble), border: Border.all(color: c.line)),
          child: Column(children: [for (var i = 0; i < rows.length; i++) ...[if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: c.line), rows[i]]]),
        );
    Widget row(String title, {String? sub, Widget? trailing, Widget? below}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: mpStyle(context, w: FontWeight.w500)),
                if (sub != null) Text(sub, style: mpStyle(context, size: MpText.meta, color: c.text2)),
              ])),
              ?trailing,
            ]),
            if (below != null) ...[const SizedBox(height: 12), below],
          ]),
        );

    return StoreBuilder(builder: (context) {
      final theme = store.get('theme', 'system');
      final accent = store.get<num>('accent', 0).toInt();
      final scale = store.get<num>('textScale', 1.0).toDouble();
      final children = <Widget>[
        const SectionLabel('This device'),
        card([
          row('Name', sub: 'How your other devices see this one', below: TextField(
            controller: _name,
            onSubmitted: (_) => _saveName(),
            onTapOutside: (_) { _saveName(); FocusScope.of(context).unfocus(); },
            style: mpStyle(context),
            decoration: InputDecoration(
              isDense: true, filled: true, fillColor: c.bg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.line)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.text2, width: 1.4)),
            ),
          )),
          row('Type', below: Row(children: [
            for (final k in ['phone', 'laptop', 'desktop', 'tablet'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Pressable(
                  onTap: () { store.set('kind', k); client.sweep(); },
                  pressScale: .9,
                  child: AnimatedContainer(
                    duration: Motion.d(220),
                    curve: Motion.curve,
                    width: 52, height: 52,
                    decoration: BoxDecoration(color: store.myKind == k ? c.text : c.surface2, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: MpIcon(k, size: 24, color: store.myKind == k ? c.bg : c.text),
                  ),
                ),
              ),
          ])),
          row('Tailscale address', sub: _ips.isEmpty ? 'Tailscale isn’t connected on this device' : '${_ips.join(' · ')} · port 4747'),
        ]),

        const SectionLabel('Appearance'),
        card([
          row('Theme', below: MpSegmented(items: const [('system', 'System'), ('light', 'Light'), ('dark', 'Dark')], value: theme, onChanged: (v) => store.set('theme', v))),
          row('Accent', sub: '${accents[accent].name} · used for your bubbles, send button and online dots', below: Wrap(spacing: 12, runSpacing: 12, children: [
            for (var i = 0; i < accents.length; i++)
              Pressable(
                onTap: () => store.set('accent', i),
                pressScale: .88,
                child: AnimatedContainer(
                  duration: Motion.d(240),
                  curve: Motion.curve,
                  width: 40, height: 40,
                  padding: EdgeInsets.all(i == accent ? 4 : 0),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: i == accent ? c.text : Colors.transparent, width: 2)),
                  child: Container(
                    decoration: BoxDecoration(color: Theme.of(context).brightness == Brightness.dark ? accents[i].dark : accents[i].light, shape: BoxShape.circle),
                    child: AnimatedOpacity(opacity: i == accent ? 1 : 0, duration: Motion.d(200), child: Center(child: MpIcon('check', size: 16, stroke: 2.2, color: accents[i].on))),
                  ),
                ),
              ),
          ])),
          row('Text size', below: MpSegmented<double>(items: const [(0.9, 'Small'), (1.0, 'Default'), (1.15, 'Large')], value: scale, onChanged: (v) => store.set('textScale', v))),
          row('Reduce motion', sub: 'Turn off animations and transitions', trailing: MpSwitch(store.get('reduceMotion', false), (v) => store.set('reduceMotion', v))),
          row('Preview', below: _Preview(c: c)),
        ]),

        const SectionLabel('Sync'),
        card([
          row('Share clipboard', sub: Platform.isAndroid ? 'Text you copy on your PC is ready to paste here. Copied something here? Tap “Send clipboard” in your Quick Settings panel (add the tile once), or just open myPhone.' : 'Copy on this PC, paste on your phone, and back.', trailing: MpSwitch(store.get('clipSync', false), (v) {
            store.set('clipSync', v);
            syncClipWatcher(store, client);
          })),
        ]),

        const SectionLabel('Notifications'),
        card([
          row('Show notifications', sub: 'When a device sends you something', trailing: MpSwitch(store.get('notify', true), (v) => store.set('notify', v))),
          row('Show message text', sub: 'Otherwise just “New message”', trailing: MpSwitch(store.get('preview', true), (v) => store.set('preview', v))),
          row('Low battery alerts', sub: 'When another device drops to 15% and isn’t charging', trailing: MpSwitch(store.get('batteryAlerts', true), (v) => store.set('batteryAlerts', v))),
        ]),

        const SectionLabel('Files'),
        card([
          row('Save received files to', sub: _saveDir, trailing: Platform.isAndroid
              ? null
              : PillButton('Change', solid: false, height: 36, onTap: () async {
                  final d = await FilePicker.getDirectoryPath();
                  if (d == null) return;
                  store.set('saveDir', d);
                  setState(() => _saveDir = d);
                })),
        ]),

        if (Platform.isAndroid) ...[
          const SectionLabel('Phone control'),
          card([const _ControlStatus()]),
          const SectionLabel('Background'),
          card([
            row('Stay connected', sub: 'Receive messages and files while the app is closed. Shows a quiet “myPhone online” notification.', trailing: MpSwitch(store.get('background', true), (v) async {
              store.set('background', v);
              await applyBackgroundMode();
            })),
          ]),
        ],

        if (isDesktop) ...[
          const SectionLabel('Background'),
          card([
            row('Keep running when closed', sub: 'Closing the window hides myPhone to the tray, so messages and notifications keep arriving. Quit from the tray menu.', trailing: MpSwitch(store.get('keepRunning', true), (v) => store.set('keepRunning', v))),
            row('Start at login', sub: 'Starts quietly in the tray when you log in.', trailing: MpSwitch(store.get('autostart', true), (v) async {
              store.set('autostart', v);
              await syncAutostart();
            })),
          ]),
          const SectionLabel('Remote access'),
          card([
            row('Allow my devices to run Claude here', sub: 'Your phone can start Claude Code sessions on this PC and approve each action. Turn off to block it completely.', trailing: MpSwitch(store.get('agentsEnabled', true), (v) => store.set('agentsEnabled', v))),
            row('Allow my phone to share its screen here', sub: 'Show and control your phone in a window on this PC.', trailing: MpSwitch(store.get('phoneControlEnabled', true), (v) => store.set('phoneControlEnabled', v))),
            row('Allow my devices to view this screen', sub: 'Live view of this PC’s screen on your phone. Only your own paired devices can connect.', trailing: MpSwitch(store.get('screenEnabled', true), (v) => store.set('screenEnabled', v))),
          ]),
        ],

        const SectionLabel('About'),
        card([row('myPhone', sub: 'Version 1.0 · peer-to-peer over Tailscale, no servers')]),
        const SizedBox(height: 32),
      ];

      final list = ListView(padding: EdgeInsets.symmetric(horizontal: widget.desktop ? 32 : 16), children: [
        for (var i = 0; i < children.length; i++) EnterAnim(key: ValueKey(i), child: children[i]),
      ]);

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.desktop)
          Container(
            height: 64,
            padding: const EdgeInsets.fromLTRB(32, 0, 16, 0),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
            child: Row(children: [
              Expanded(child: Text('Settings', style: mpStyle(context, size: MpText.title, w: FontWeight.w700))),
              IconBtn('close', size: 36, iconSize: 20, onTap: widget.onClose, tip: 'Close'),
            ]),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 0),
            child: Row(children: [
              IconBtn('back', iconSize: 24, onTap: widget.onClose),
              const SizedBox(width: 8),
              Text('Settings', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
            ]),
          ),
        Expanded(child: widget.desktop ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: list)) : list),
      ]);
    });
  }
}

/// Live sample of the chosen look.
class _Preview extends StatelessWidget {
  final MpColors c;
  const _Preview({required this.c});
  @override
  Widget build(BuildContext context) {
    Widget b(String t, bool mine) => Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedContainer(
            duration: Motion.d(300),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            decoration: BoxDecoration(
              color: mine ? c.accent : c.surface2,
              borderRadius: BorderRadius.only(topLeft: const Radius.circular(20), topRight: const Radius.circular(20), bottomLeft: Radius.circular(mine ? 20 : 6), bottomRight: Radius.circular(mine ? 6 : 20)),
            ),
            child: Text(t, style: mpStyle(context, color: mine ? c.onAccent : c.text)),
          ),
        );
    return AnimatedContainer(
      duration: Motion.d(300),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: c.line)),
      child: Column(children: [b('Build finished. Logs attached.', false), b('Thanks, opening it now.', true)]),
    );
  }
}


/// Android: is the accessibility part (PC control) on, and is screen sharing running?
class _ControlStatus extends StatefulWidget {
  const _ControlStatus();
  @override
  State<_ControlStatus> createState() => _ControlStatusState();
}

class _ControlStatusState extends State<_ControlStatus> with WidgetsBindingObserver {
  Map _s = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh(); // back from Android settings
  }

  Future<void> _refresh() async {
    final s = await mirrorStatus().catchError((_) => const {});
    if (mounted) setState(() => _s = s);
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final on = _s['control'] == true, sharing = _s['sharing'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Let my PC control this phone', style: mpStyle(context, w: FontWeight.w500))),
          AnimatedSwitcher(
            duration: Motion.d(200),
            child: Text(on ? 'On' : 'Off', key: ValueKey(on), style: mpStyle(context, size: MpText.meta, w: FontWeight.w700, color: on ? c.text : c.text2)),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
          'On your PC, open this phone’s chat and press the control button. Android asks you to confirm screen sharing every time. '
          'For taps and typing, enable “myPhone control” in Accessibility (Xiaomi: if it’s greyed out, open App info → ⋮ → Allow restricted settings first).',
          style: mpStyle(context, size: MpText.meta, color: c.text2),
        ),
        const SizedBox(height: 12),
        Row(children: [
          PillButton(on ? 'Accessibility settings' : 'Turn on control', solid: !on, height: 40, onTap: openControlSettings),
          const SizedBox(width: 8),
          if (sharing) PillButton('Stop sharing', solid: false, height: 40, onTap: () async {
            await stopSharing();
            await Future.delayed(const Duration(milliseconds: 300));
            _refresh();
          }),
        ]),
      ]),
    );
  }
}

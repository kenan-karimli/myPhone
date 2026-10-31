import 'package:flutter/material.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'widgets.dart';

enum AddState { idle, searching, found, failed }

/// Form shared by the phone page and the desktop dialog.
class AddDeviceForm extends StatefulWidget {
  final bool desktop;
  final void Function(Device) onAdded;
  final VoidCallback? onCancel;
  const AddDeviceForm({super.key, required this.onAdded, this.desktop = false, this.onCancel});
  @override
  State<AddDeviceForm> createState() => _AddDeviceFormState();
}

class _AddDeviceFormState extends State<AddDeviceForm> {
  final _name = TextEditingController();
  AddState _state = AddState.idle;
  Device? _found;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {
          if (_state != AddState.searching) _state = AddState.idle;
        }));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _name.text.trim().toLowerCase();
    if (host.isEmpty || _state == AddState.searching) return;
    setState(() => _state = AddState.searching);
    try {
      final d = await client.hello(host);
      if (d.id == store.myId) throw 'That’s this device.';
      if (!mounted) return;
      setState(() {
        _found = d;
        _state = AddState.found;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is String ? e : '';
        _state = AddState.failed;
      });
    }
  }

  Future<void> _add() async {
    final d = _found!;
    await store.upsertDevice(d);
    store.setPresence(d.id, true);
    await store.loadChat(d.id);
    widget.onAdded(d);
  }

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final busy = _state == AddState.searching;
    final card = AnimatedSize(
      duration: Motion.d(260),
      curve: Motion.curve,
      child: AnimatedSwitcher(
        duration: Motion.d(240),
        switchInCurve: Motion.curve,
        transitionBuilder: (w, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0, .08), end: Offset.zero).animate(a), child: w)),
        child: switch (_state) {
          AddState.idle => const SizedBox(width: double.infinity, key: ValueKey('idle')),
          AddState.searching => _Card(key: const ValueKey('s'), child: Row(children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: c.text, backgroundColor: c.line, strokeCap: StrokeCap.round)),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Searching…', style: mpStyle(context, w: FontWeight.w700)),
                Text('Looking for ${_name.text.trim()} on your tailnet', style: mpStyle(context, size: MpText.meta, color: c.text2)),
              ])),
            ])),
          AddState.found => _Card(key: const ValueKey('f'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                DeviceAvatar(_found!.kind, size: 48, online: true),
                const SizedBox(width: 16),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_found!.name, style: mpStyle(context, w: FontWeight.w700)),
                  Text('${_found!.kind[0].toUpperCase()}${_found!.kind.substring(1)} · ${_found!.host} · Online', maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, size: MpText.meta, color: c.text2)),
                ])),
                if (widget.desktop) const MpIcon('check', size: 20, stroke: 1.8),
              ]),
              if (!widget.desktop) ...[const SizedBox(height: 16), PillButton('Add to myPhone', solid: false, onTap: _add, expand: true)],
            ])),
          AddState.failed => _Card(key: const ValueKey('x'), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MpIcon('error', color: c.text2),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Couldn’t find “${_name.text.trim()}”', style: mpStyle(context, w: FontWeight.w700)),
                Text(_error.isNotEmpty ? _error : 'Check the spelling, and that Tailscale and myPhone are running on both devices.', style: mpStyle(context, size: MpText.meta, color: c.text2)),
              ])),
            ])),
        },
      ),
    );

    final field = TextField(
      controller: _name,
      autofocus: true,
      autocorrect: false,
      enableSuggestions: false,
      onSubmitted: (_) => _state == AddState.found ? _add() : _connect(),
      style: mpStyle(context),
      decoration: InputDecoration(
        hintText: widget.desktop ? 'e.g. pixel-8' : 'e.g. thinkpad',
        hintStyle: mpStyle(context, color: c.text2.withValues(alpha: .7)),
        filled: true,
        fillColor: widget.desktop ? c.bg : c.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(widget.desktop ? 10 : 16), borderSide: BorderSide(color: _state == AddState.failed ? c.text2 : c.line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(widget.desktop ? 10 : 16), borderSide: BorderSide(color: c.text2, width: 1.4)),
      ),
    );
    final label = Text('Device name (Tailscale name)', style: mpStyle(context, size: MpText.meta, w: FontWeight.w500, color: c.text2));

    if (widget.desktop) {
      final primary = switch (_state) { AddState.searching => 'Connecting…', AddState.found => 'Add device', AddState.failed => 'Try again', _ => 'Connect' };
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Add a device', style: mpStyle(context, size: MpText.title, w: FontWeight.w700))),
          IconBtn('close', size: 36, iconSize: 20, color: c.text2, onTap: widget.onCancel),
        ]),
        const SizedBox(height: 8),
        Text('Enter the name the device uses on your Tailscale network. It needs myPhone running.', style: mpStyle(context, color: c.text2)),
        const SizedBox(height: 16),
        label,
        const SizedBox(height: 6),
        field,
        card,
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          PillButton('Cancel', solid: false, height: 44, onTap: widget.onCancel),
          const SizedBox(width: 8),
          PillButton(primary, height: 44, onTap: busy || _name.text.trim().isEmpty ? null : (_state == AddState.found ? _add : _connect)),
        ]),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          label,
          const SizedBox(height: 8),
          field,
          const SizedBox(height: 8),
          Text('Both devices need to be on the same tailnet.', style: mpStyle(context, size: MpText.meta, color: c.text2)),
          const SizedBox(height: 24),
          PillButton('Connect', height: 52, expand: true, onTap: busy || _name.text.trim().isEmpty ? null : _connect),
        ]),
      ),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: card),
    ]);
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: MpColors.of(context).surface, borderRadius: BorderRadius.circular(MpRadius.bubble), border: Border.all(color: MpColors.of(context).line)),
        child: child,
      );
}

class AddDevicePage extends StatelessWidget {
  const AddDevicePage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
              child: Row(children: [
                IconBtn('back', iconSize: 24, onTap: () => Navigator.pop(context)),
                const SizedBox(width: 8),
                Text('Add device', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
              ]),
            ),
            AddDeviceForm(onAdded: (d) {
              Navigator.pop(context);
              showToast(context, '${d.name} added');
            }),
          ]),
        ),
      );
}

Future<void> showAddDeviceDialog(BuildContext context, void Function(Device) onAdded) => showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: MpColors.of(context).scrim,
      transitionDuration: Motion.d(240),
      pageBuilder: (ctx, _, _) => Center(
        child: Material(
          color: MpColors.of(ctx).surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: MpColors.of(ctx).line)),
          child: Container(
            width: 400,
            padding: const EdgeInsets.all(24),
            child: AddDeviceForm(
              desktop: true,
              onCancel: () => Navigator.pop(ctx),
              onAdded: (d) {
                Navigator.pop(ctx);
                onAdded(d);
              },
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, a, _, child) => popTransition(a, child),
    );

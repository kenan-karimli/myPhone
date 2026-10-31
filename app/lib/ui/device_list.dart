import 'package:flutter/material.dart';

import '../core.dart';
import '../store.dart';
import '../tokens.dart';
import 'widgets.dart';

List<Device> sortedDevices() {
  final l = store.devices.values.toList();
  int last(Device d) => store.chat(d.id).isEmpty ? 0 : store.chat(d.id).last.ts;
  l.sort((a, b) => last(b).compareTo(last(a)));
  return l;
}

class DeviceList extends StatelessWidget {
  final void Function(Device) onOpen;
  final String? selected;
  final bool desktop;
  const DeviceList({super.key, required this.onOpen, this.selected, this.desktop = false});

  @override
  Widget build(BuildContext context) => StoreBuilder(builder: (context) {
        final devs = sortedDevices();
        // AnimatedSwitcher per row keeps reorders calm; new rows rise in.
        return ListView.builder(
          padding: EdgeInsets.symmetric(horizontal: desktop ? 8 : 12, vertical: 0),
          itemCount: devs.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: EnterAnim(key: ValueKey(devs[i].id), child: _Row(devs[i], selected: devs[i].id == selected, desktop: desktop, onTap: () => onOpen(devs[i]))),
          ),
        );
      });
}

class _Row extends StatelessWidget {
  final Device d;
  final bool selected, desktop;
  final VoidCallback onTap;
  const _Row(this.d, {required this.selected, required this.desktop, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    final on = store.online[d.id] == true;
    final unread = store.unread(d.id);
    final l = store.chat(d.id);
    final meta = mpStyle(context, size: MpText.meta, color: c.text2);
    return Pressable(
      onTap: onTap,
      pressScale: .98,
      radius: BorderRadius.circular(desktop ? 10 : MpRadius.bubble),
      color: selected ? (desktop ? c.surface2 : c.surface) : null,
      hover: desktop ? c.surface2 : c.surface,
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        desktop ? DeviceAvatar(d.kind, size: 40, square: true, online: on) : Hero(tag: 'avatar-${d.id}', child: DeviceAvatar(d.kind, size: 48)),
        SizedBox(width: desktop ? 12 : 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Row(children: [
                  Flexible(child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mpStyle(context, w: FontWeight.w700))),
                  if (!desktop) ...[const SizedBox(width: 8), on ? const OnlineDot(true) : Flexible(child: Text(statusOf(d.id), maxLines: 1, overflow: TextOverflow.ellipsis, style: meta))],
                ]),
              ),
              const SizedBox(width: 8),
              Text(desktop ? (on ? 'Online' : statusOf(d.id).replaceFirst('last seen ', 'Seen ')) : (l.isEmpty ? '' : timeLabel(l.last.ts)), style: meta),
            ]),
            const SizedBox(height: 2),
            Row(children: [
              Expanded(child: Text(previewFor(d), maxLines: 1, overflow: TextOverflow.ellipsis, style: desktop ? meta : mpStyle(context, color: c.text2))),
              if (store.battery[d.id] != null) Padding(padding: const EdgeInsets.only(left: 8), child: BatteryChip(d.id, compact: desktop)),
              AnimatedSwitcher(
                duration: Motion.d(240),
                transitionBuilder: (w, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Motion.pop), child: w),
                child: unread == 0
                    ? const SizedBox.shrink()
                    : Container(
                        key: ValueKey(unread),
                        margin: const EdgeInsets.only(left: 8),
                        constraints: const BoxConstraints(minWidth: 20),
                        height: 20,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: c.text, borderRadius: BorderRadius.circular(999)),
                        child: Text('$unread', style: mpStyle(context, size: 12, w: FontWeight.w700, color: c.bg)),
                      ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class EmptyDevices extends StatelessWidget {
  final VoidCallback onAdd;
  final bool desktop;
  const EmptyDevices({super.key, required this.onAdd, this.desktop = false});
  @override
  Widget build(BuildContext context) {
    final c = MpColors.of(context);
    return Center(
      child: EnterAnim(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 0, 48, 64),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (final k in ['phone', 'laptop', 'desktop']) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: MpIcon(k, size: 32, stroke: 1.4, color: c.text3)),
            ]),
            const SizedBox(height: 24),
            Text(desktop ? 'Add your first device' : 'No devices yet', style: mpStyle(context, size: MpText.title, w: FontWeight.w700)),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                desktop ? 'Install myPhone on your phone, then add it here using its Tailscale name.' : 'Add a laptop, desktop or tablet by its Tailscale name. Each one shows up here as its own conversation.',
                textAlign: TextAlign.center,
                style: mpStyle(context, color: c.text2),
              ),
            ),
            const SizedBox(height: 24),
            PillButton(desktop ? 'Add device' : 'Add a device', icon: desktop ? 'add' : null, onTap: onAdd),
          ]),
        ),
      ),
    );
  }
}

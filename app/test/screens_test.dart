// Renders real screens to test/goldens/*.png for visual review:
//   flutter test --update-goldens test/screens_test.dart
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/core.dart';
import 'package:myphone/main.dart';
import 'package:myphone/net.dart';
import 'package:myphone/store.dart';
import 'package:myphone/ui/chat.dart';

Future<void> seed() async {
  final dir = Directory.systemTemp.createTempSync('shots');
  store = await Store.open(dir);
  store.settings.addAll({'name': 'workstation', 'kind': 'desktop'});
  client = Client(store);
  final t = DateTime.now();
  final now = DateTime(t.year, t.month, t.day, 12).millisecondsSinceEpoch; // fixed clock: stable goldens
  int ago(int min) => now - min * 60000;
  final devs = [
    Device(id: 'pixel', name: 'pixel-8', kind: 'phone', host: 'pixel-8', addr: '100.84.12.7'),
    Device(id: 'thinkpad', name: 'thinkpad', kind: 'laptop', host: 'thinkpad', addr: '100.71.40.2'),
    Device(id: 'tab', name: 'galaxy-tab', kind: 'tablet', host: 'galaxy-tab'),
  ];
  for (final d in devs) {
    await store.upsertDevice(d);
  }
  store.setPresence('pixel', true);
  store.setBattery('pixel', {'level': 82, 'charging': false});
  store.setBattery('thinkpad', {'level': 11, 'charging': false});
  store.lastSeen['thinkpad'] = DateTime.now().subtract(const Duration(hours: 2, minutes: 30));
  store.online['thinkpad'] = false;
  final msgs = [
    Msg(id: 'a', kind: 'text', mine: false, text: 'Build finished. Logs attached.', ts: ago(30)),
    Msg(id: 'b', kind: 'file', mine: false, name: 'build-log.txt', size: 18000, path: '/nope', ts: ago(29)),
    Msg(id: 'c', kind: 'text', mine: true, text: 'Thanks. Can you send the slides from Desktop/talk?', ts: ago(25)),
    Msg(id: 'd', kind: 'file', mine: false, name: 'talk-final.pdf', size: 4400000, path: '/nope', ts: ago(24)),
    Msg(id: 'e', kind: 'image', mine: true, name: 'IMG_2041.jpg', path: '/nope', ts: ago(20)),
    Msg(id: 'f', kind: 'text', mine: false, text: 'Saved to ~/Pictures/phone.', ts: ago(18), replyTo: {'who': 'You', 'text': 'Photo · IMG_2041.jpg'}),
    Msg(id: 'g', kind: 'file', mine: true, name: 'notes.zip', size: 12800000, path: '/nope', ts: ago(2), status: 'pending')..progress = .62,
  ];
  for (final m in msgs) {
    await store.addMsg('pixel', m);
  }
  await store.logEvent('pixel', {'t': 'react', 'id': 'd', 'e': '👍', 'by': 'me', 'on': true});
  await store.logEvent('pixel', {'t': 'react', 'id': 'f', 'e': '❤️', 'by': 'them', 'on': true});
  await store.markRead('pixel');
  await store.addMsg('thinkpad', Msg(id: 'h', kind: 'text', mine: false, text: 'Nightly backup complete. 3.1 GB copied.', ts: ago(130)));
}

Future<void> loadFont() async {
  final l = FontLoader('MPlusRounded');
  for (final w in ['Regular', 'Medium', 'Bold']) {
    l.addFont(rootBundle.load('assets/fonts/MPLUSRounded1c-$w.ttf'));
  }
  await l.load();
}

Future<void> shot(WidgetTester t, String name, Size size, {String theme = 'dark', Future<void> Function()? act}) async {
  await t.runAsync(() async => store.set('theme', theme));
  await t.binding.setSurfaceSize(size);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await t.pumpWidget(const MyPhoneApp());
  await t.pumpAndSettle();
  if (act != null) {
    await act();
    await t.pumpAndSettle();
  }
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  setUpAll(() async {
    await loadFont();
  });

  for (final theme in ['dark', 'light']) {
    testWidgets('phone $theme', (t) async {
      await t.runAsync(seed);
      await shot(t, 'phone_home_$theme', const Size(412, 915), theme: theme);
      await t.tap(find.text('pixel-8'));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/phone_chat_$theme.png'));
    });

    testWidgets('desktop $theme', (t) async {
      await t.runAsync(seed);
      await shot(t, 'desktop_empty_$theme', const Size(1280, 800), theme: theme);
      await t.tap(find.text('pixel-8'));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Device info'));
      await t.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/desktop_chat_$theme.png'));
      await t.tap(find.byTooltip('Settings'));
      await t.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/desktop_settings_$theme.png'));
    });
  }

  testWidgets('desktop: hover bar reaction is clickable', (t) async {
    await t.runAsync(seed);
    await shot(t, 'desktop_empty_dark', const Size(1280, 800));
    await t.tap(find.text('pixel-8'));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.text('Saved to ~/Pictures/phone.')));
    await t.pumpAndSettle();
    expect(store.chat('pixel').firstWhere((m) => m.id == 'f').reacts['👍'], isNull);
    final tile = find.ancestor(of: find.text('Saved to ~/Pictures/phone.'), matching: find.byType(MsgTile));
    await mouse.moveTo(t.getCenter(find.descendant(of: tile, matching: find.text('👍'))));
    await t.pump();
    await mouse.down(t.getCenter(find.descendant(of: tile, matching: find.text('👍'))));
    await mouse.up();
    for (var i = 0; i < 5; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await t.pump();
    }
    await t.runAsync(() => store.loadChat('pixel')); // re-read what react() wrote to disk
    expect(store.chat('pixel').firstWhere((m) => m.id == 'f').reacts['👍'], contains('me'));
  });

  testWidgets('search narrows the chat to matches', (t) async {
    await t.runAsync(seed);
    await shot(t, 'phone_home_dark', const Size(412, 915));
    await t.tap(find.text('pixel-8'));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await t.pumpAndSettle();
    expect(find.text('talk-final.pdf'), findsOneWidget);
    await t.tap(find.byTooltip('Search'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, 'pictures');
    await t.pumpAndSettle();
    expect(find.text('1 result'), findsOneWidget);
    expect(find.text('talk-final.pdf'), findsNothing);
    expect(find.textContaining('Saved to', findRichText: true), findsOneWidget);
  });
}

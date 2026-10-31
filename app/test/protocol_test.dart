import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/clipboard.dart';
import 'package:myphone/net.dart';
import 'package:myphone/store.dart';

class Peer {
  late Store store;
  late Node node;
  late Client client;
  late Directory saves;
  final incoming = <Msg?>[];
  final events = <Map>[];
  final int port;
  Peer(this.port);

  Future<void> start(Directory root, String name) async {
    store = await Store.open(Directory('${root.path}/$name'));
    store.set('name', name);
    saves = Directory('${root.path}/$name-downloads');
    node = Node(store, saveDir: () async => saves, onIncoming: (d, m) => incoming.add(m), onAgent: (d, ev) => events.add(ev));
    await node.start(listenPort: port);
    client = Client(store, myPort: port);
  }
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 100 && !ok(); i++) {
    await Future.delayed(const Duration(milliseconds: 30));
  }
  expect(ok(), isTrue);
}

void main() {
  test('tailnet filter', () {
    expect(allowedPeer(InternetAddress('100.84.12.7')), isTrue);
    expect(allowedPeer(InternetAddress('100.127.255.1')), isTrue);
    expect(allowedPeer(InternetAddress('100.128.0.1')), isFalse);
    expect(allowedPeer(InternetAddress('192.168.1.5')), isFalse);
    expect(allowedPeer(InternetAddress('::ffff:100.70.1.1')), isTrue);
    expect(allowedPeer(InternetAddress('fd7a:115c:a1e0::1')), isTrue);
    expect(allowedPeer(InternetAddress('127.0.0.1')), isTrue);
  });

  test('pair, text, file, reaction, offline retry', () async {
    final root = await Directory.systemTemp.createTemp('myphone');
    final a = Peer(4801), b = Peer(4802);
    await a.start(root, 'pc');
    await b.start(root, 'pixel');

    // pair: A adds B by address; B learns A from the hello.
    final bDev = await a.client.hello('127.0.0.1:4802');
    await a.store.upsertDevice(bDev);
    expect(bDev.name, 'pixel');
    final aDev = b.store.devices[a.store.myId]!;
    expect(aDev.name, 'pc');

    // text with reply quote
    final m = await a.client.sendText(bDev, 'hello 👋', replyTo: {'who': 'You', 'text': 'x'});
    await until(() => b.store.chat(aDev.id).length == 1);
    expect(b.store.chat(aDev.id).single.text, 'hello 👋');
    expect(b.store.chat(aDev.id).single.replyTo!['who'], 'You');
    await until(() => m.status == 'sent');

    // file, byte-exact
    final src = File('${root.path}/big.bin')..writeAsBytesSync(List.generate(3 * 1024 * 1024 + 7, (i) => i * 31 % 256));
    final fm = await a.client.sendFile(bDev, src.path);
    await until(() => fm.status == 'sent');
    final got = b.store.chat(aDev.id).last;
    expect(got.kind, 'file');
    expect(File(got.path).readAsBytesSync(), src.readAsBytesSync());

    // reaction from B shows on A
    await b.client.react(aDev, m.id, '❤️');
    await until(() => a.store.chat(bDev.id).first.reacts['❤️']?.contains('them') ?? false);

    // offline: stop B, send, restart B, sweep delivers once
    await b.node.stop();
    final late = await a.client.sendText(bDev, 'are you there?');
    await Future.delayed(const Duration(milliseconds: 300));
    expect(late.status, 'pending');
    await b.node.start(listenPort: 4802);
    await a.client.sweep();
    await until(() => late.status == 'sent');
    await a.client.sweep(); // must not duplicate
    expect(b.store.chat(aDev.id).where((x) => x.text == 'are you there?').length, 1);

    // everything survives a reload from disk
    final again = await Store.open(b.store.dir);
    await again.loadChat(aDev.id);
    expect(again.chat(aDev.id).length, 3);
    expect(again.chat(aDev.id).first.reacts['❤️'], {'me'});

    await a.node.stop();
    await b.node.stop();
    a.client.close();
    b.client.close();
    await root.delete(recursive: true);
  });

  test('file manager share endpoint (loopback only)', () async {
    final root = await Directory.systemTemp.createTemp('myphone');
    final store = await Store.open(Directory('${root.path}/s'));
    final got = <List<String>>[];
    final node = Node(store, saveDir: () async => root, onIncoming: (_, _) {}, onShare: got.add);
    await node.start(listenPort: 4803);
    final real = File('${root.path}/a b.txt')..writeAsStringSync('x');
    final http = HttpClient();
    final req = await http.postUrl(Uri.parse('http://127.0.0.1:4803/share'));
    req.write('${real.path}\n/does/not/exist\n');
    final res = await req.close();
    await res.drain();
    expect(res.statusCode, 200);
    expect(got, [
      [real.path]
    ]);
    http.close();
    await node.stop();
    await root.delete(recursive: true);
  });

  test('battery rides along with hello; low alert fires once', () async {
    final root = await Directory.systemTemp.createTemp('myphone');
    final a = Peer(4805), b = Peer(4806);
    await a.start(root, 'pc');
    await b.start(root, 'phone');
    b.store.myBattery = {'level': 12, 'charging': false};
    final lows = <Map>[];
    a.store.onLowBattery = (id, bat) => lows.add(bat);
    final phone = await a.client.hello('127.0.0.1:4806');
    expect(a.store.battery[phone.id]!['level'], 12);
    await a.client.hello('127.0.0.1:4806');
    expect(lows.length, 1); // not again while still low
    b.store.myBattery = {'level': 40, 'charging': true};
    await a.client.hello('127.0.0.1:4806');
    expect(a.store.battery[phone.id]!['charging'], isTrue);
    expect(lows.length, 1);
    await a.node.stop();
    await b.node.stop();
    a.client.close();
    b.client.close();
    await root.delete(recursive: true);
  });

  test('clipboard sync: off by default, sends once when on', () async {
    final root = await Directory.systemTemp.createTemp('myphone');
    final a = Peer(4807), b = Peer(4808);
    await a.start(root, 'pc');
    await b.start(root, 'phone');
    final phone = await a.client.hello('127.0.0.1:4808');
    await a.store.upsertDevice(phone);
    a.store.setPresence(phone.id, true);

    sendClip(a.store, a.client, 'secret'); // switch off: nothing leaves this device
    await Future.delayed(const Duration(milliseconds: 300));
    expect(b.events, isEmpty);

    a.store.set('clipSync', true);
    sendClip(a.store, a.client, 'hello from pc');
    sendClip(a.store, a.client, 'hello from pc'); // same text: not again
    await until(() => b.events.isNotEmpty);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(b.events, [
      {'t': 'clip', 'text': 'hello from pc'}
    ]);
    await a.node.stop();
    await b.node.stop();
    a.client.close();
    b.client.close();
    await root.delete(recursive: true);
  });
}

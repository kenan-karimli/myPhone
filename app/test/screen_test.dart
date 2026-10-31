import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/net.dart';
import 'package:myphone/screen.dart';
import 'package:myphone/store.dart';

void main() {
  test('JpegSplitter: frames across chunk boundaries, escaped FF00 inside', () {
    final f1 = [0xFF, 0xD8, 1, 0xFF, 0x00, 2, 0xFF, 0xD9];
    final f2 = [0xFF, 0xD8, 3, 4, 0xFF, 0xD9];
    final all = [...f1, ...f2];
    final s = JpegSplitter();
    final got = <List<int>>[];
    for (var i = 0; i < all.length; i += 3) {
      got.addAll(s.add(all.sublist(i, i + 3 > all.length ? all.length : i + 3)));
    }
    expect(got, [f1, f2]);
  });

  test('phone receives live frames from the PC; strangers are refused', () async {
    final root = await Directory.systemTemp.createTemp('screen');
    final pcStore = await Store.open(Directory('${root.path}/pc'));
    final phoneStore = await Store.open(Directory('${root.path}/phone'));
    final host = ScreenHost(pcStore, command: (_, _) => ['${Directory.current.path}/test/fixtures/fake_recorder.py']);
    final node = Node(pcStore, saveDir: () async => root, onIncoming: (_, _) {}, extraRoutes: host.handle);
    await node.start(listenPort: 4821);
    final phoneNode = Node(phoneStore, saveDir: () async => root, onIncoming: (_, _) {});
    await phoneNode.start(listenPort: 4822);
    final phone = Client(phoneStore, myPort: 4822);
    final pc = await phone.hello('127.0.0.1:4821');

    // ScreenHost.available needs wf-recorder on PATH; skip the live part if this machine lacks it.
    if (!ScreenHost.available) {
      markTestSkipped('wf-recorder not installed');
    } else {
      final frames = <Uint8List>[];
      final sub = phone.screen(pc, 'low').listen(frames.add);
      for (var i = 0; i < 100 && frames.length < 3; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(frames.length, 3);
      expect(frames[1][4], 1);
      expect(frames.every((f) => f[0] == 0xFF && f[1] == 0xD8 && f[f.length - 1] == 0xD9), isTrue);
      await sub.cancel();
      expect(host.capturing, isTrue);
      await Future.delayed(const Duration(seconds: 7)); // keep-alive notices (≤2 s) + 3 s grace
      expect(host.capturing, isFalse, reason: 'recorder should stop when the last viewer leaves');
    }

    final stranger = Client(await Store.open(Directory('${root.path}/x')));
    await expectLater(stranger.screen(Device(id: 'pc', name: 'pc', kind: 'desktop', host: '127.0.0.1:4821'), 'low').first, throwsA(isA<HttpException>()));

    host.dispose();
    phone.close();
    stranger.close();
    await node.stop();
    await phoneNode.stop();
    await root.delete(recursive: true);
  });
}

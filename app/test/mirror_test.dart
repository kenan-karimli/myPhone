import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myphone/mirror.dart';
import 'package:myphone/store.dart';

List<int> frame(int type, List<int> payload) => [type, ...(ByteData(4)..setUint32(0, payload.length)).buffer.asUint8List(), ...payload];

void main() {
  test('phone streams H.264 to the PC: decoded frames out, input events back; strangers refused', () async {
    final root = await Directory.systemTemp.createTemp('mirror');
    final store = await Store.open(Directory('${root.path}/pc'));
    await store.upsertDevice(Device(id: 'phone1', name: 'phone', kind: 'phone', host: '127.0.0.1'));
    final host = MirrorHost(store);
    await host.start(port: 4831);

    // Unknown device: dropped.
    final stranger = await Socket.connect('127.0.0.1', 4831);
    stranger.add(frame(0, utf8.encode(jsonEncode({'id': 'nobody'}))));
    await stranger.flush();
    await stranger.drain<void>().timeout(const Duration(seconds: 3));
    expect(host.sessions, isEmpty);

    // Real H.264 like the phone's encoder makes (Annex-B, 10 frames).
    final r = await Process.run('ffmpeg', ['-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc=size=320x640:rate=10', '-frames:v', '10', '-c:v', 'libx264', '-tune', 'zerolatency', '-f', 'h264', 'pipe:1'], stdoutEncoding: null);
    final h264 = r.stdout as List<int>;
    expect(h264.length, greaterThan(1000));

    final phone = await Socket.connect('127.0.0.1', 4831);
    final back = <int>[];
    phone.listen(back.addAll);
    phone.add(frame(0, utf8.encode(jsonEncode({'id': 'phone1'}))));
    phone.add(frame(1, utf8.encode(jsonEncode({'w': 320, 'h': 640, 'control': true}))));
    for (var i = 0; i < h264.length; i += 4096) {
      phone.add(frame(2, h264.sublist(i, i + 4096 > h264.length ? h264.length : i + 4096)));
    }
    await phone.flush();

    for (var i = 0; i < 100 && host.sessions['phone1']?.last == null; i++) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    final s = host.sessions['phone1']!;
    expect([s.w, s.h, s.control], [320, 640, true]);
    expect(s.last![0] == 0xFF && s.last![1] == 0xD8, isTrue, reason: 'decoded JPEG frame');

    s.input({'a': 'tap', 'x': .5, 'y': .25});
    for (var i = 0; i < 40 && back.length < 5; i++) {
      await Future.delayed(const Duration(milliseconds: 25));
    }
    final len = ByteData.sublistView(Uint8List.fromList(back), 1, 5).getUint32(0);
    expect(back[0], 10);
    expect(jsonDecode(utf8.decode(back.sublist(5, 5 + len))), {'a': 'tap', 'x': .5, 'y': .25});

    s.close(); // PC closes the window -> phone connection ends
    await phone.done.timeout(const Duration(seconds: 3)).catchError((_) => phone);
    expect(host.sessions, isEmpty);
    await host.stop();
    await root.delete(recursive: true);
  });
}

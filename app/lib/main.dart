import 'package:flutter/material.dart';

import 'core.dart';
import 'desktop.dart';
import 'tokens.dart';
import 'ui/home.dart';

Future<void> main(List<String> args) async {
  await boot();
  if (isDesktop) await initDesktop(args);
  runApp(const MyPhoneApp());
  handleLaunchNotification();
}

class MyPhoneApp extends StatelessWidget {
  const MyPhoneApp({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final accent = accents[store.get<num>('accent', 0).toInt().clamp(0, accents.length - 1)];
          final mode = {'light': ThemeMode.light, 'dark': ThemeMode.dark}[store.get('theme', 'system')] ?? ThemeMode.system;
          return MaterialApp(
            title: 'myPhone',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(false, accent),
            darkTheme: buildTheme(true, accent),
            themeMode: mode,
            themeAnimationDuration: Motion.d(400),
            themeAnimationCurve: Motion.curve,
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              Motion.reduce = store.get('reduceMotion', false) || mq.disableAnimations;
              return MediaQuery(
                data: mq.copyWith(textScaler: TextScaler.linear(store.get<num>('textScale', 1.0).toDouble())),
                child: child!,
              );
            },
            home: const Home(),
          );
        },
      );
}

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Colour tokens from the Claude Design handoff (design/mobile + design/desktop).
/// Lerps, so theme and accent changes animate smoothly.
class MpColors extends ThemeExtension<MpColors> {
  final Color bg, surface, surface2, line, text, text2, text3, accent, onAccent, onAccentSub, dot, quote, imgPh, scrim;
  const MpColors({
    required this.bg, required this.surface, required this.surface2, required this.line,
    required this.text, required this.text2, required this.text3, required this.accent,
    required this.onAccent, required this.onAccentSub, required this.dot, required this.quote,
    required this.imgPh, required this.scrim,
  });

  static MpColors of(BuildContext c) => Theme.of(c).extension<MpColors>()!;

  static MpColors build(bool dark, Accent a) => dark
      ? MpColors(bg: const Color(0xFF0F1011), surface: const Color(0xFF181A1B), surface2: const Color(0xFF232627),
          line: const Color(0xFF2C3031), text: const Color(0xFFEDEEEA), text2: const Color(0xFF9A9F9C),
          text3: const Color(0xFF5A5F5C), accent: a.dark, onAccent: a.on, onAccentSub: a.on.withValues(alpha: .62),
          dot: a.dark, quote: a.on.withValues(alpha: .10), imgPh: const Color(0xFF2C3031), scrim: const Color(0x9E000000))
      : MpColors(bg: const Color(0xFFF7F6F2), surface: const Color(0xFFFFFFFF), surface2: const Color(0xFFEAE8E2),
          line: const Color(0xFFE0DED7), text: const Color(0xFF151716), text2: const Color(0xFF5F6562),
          text3: const Color(0xFFB4B7B4), accent: a.light, onAccent: a.on, onAccentSub: a.on.withValues(alpha: .62),
          dot: a.dot, quote: a.on.withValues(alpha: .08), imgPh: const Color(0xFFD9D7D0), scrim: const Color(0x52151716));

  @override
  MpColors copyWith() => this;

  @override
  MpColors lerp(MpColors? o, double t) {
    if (o == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return MpColors(bg: l(bg, o.bg), surface: l(surface, o.surface), surface2: l(surface2, o.surface2),
        line: l(line, o.line), text: l(text, o.text), text2: l(text2, o.text2), text3: l(text3, o.text3),
        accent: l(accent, o.accent), onAccent: l(onAccent, o.onAccent), onAccentSub: l(onAccentSub, o.onAccentSub),
        dot: l(dot, o.dot), quote: l(quote, o.quote), imgPh: l(imgPh, o.imgPh), scrim: l(scrim, o.scrim));
  }
}

class Accent {
  final String name;
  final Color dark, light, dot, on;
  const Accent(this.name, this.dark, this.light, this.dot, this.on);
}

const accents = [
  Accent('Ember', Color(0xFFF26B3A), Color(0xFFF26B3A), Color(0xFFE0582A), Color(0xFF141414)),
  Accent('Mint', Color(0xFF7ADBA9), Color(0xFF6CD3A0), Color(0xFF2FA56E), Color(0xFF0C1F15)),
  Accent('Sky', Color(0xFF7DB8F5), Color(0xFF6AAAF0), Color(0xFF2F7BD0), Color(0xFF0B1A2C)),
  Accent('Lilac', Color(0xFFB9A2F5), Color(0xFFAE95F0), Color(0xFF7A5BD6), Color(0xFF1A1230)),
  Accent('Rose', Color(0xFFF59AB8), Color(0xFFF08AAD), Color(0xFFD24A7A), Color(0xFF2C0E19)),
  Accent('Sun', Color(0xFFF5CF5F), Color(0xFFF2C744), Color(0xFFC79A10), Color(0xFF231B04)),
];

abstract class MpSpace { static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, xxl = 32.0, xxxl = 48.0; }
abstract class MpRadius { static const tail = 6.0, tile = 12.0, field = 16.0, bubble = 20.0, sheet = 28.0, pill = 999.0; }
abstract class MpText { static const meta = 13.0, body = 15.0, title = 20.0; }

ThemeData buildTheme(bool dark, Accent a) {
  final c = MpColors.build(dark, a);
  final base = ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: c.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: a.dark, brightness: dark ? Brightness.dark : Brightness.light, surface: c.bg),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.text, selectionColor: c.accent.withValues(alpha: .4)),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
    }),
    fontFamily: font,
    extensions: [c],
  );
  return base.copyWith(textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text));
}

const font = 'MPlusRounded';

TextStyle mpStyle(BuildContext c, {double size = MpText.body, FontWeight w = FontWeight.w400, Color? color}) =>
    TextStyle(fontFamily: font, fontSize: size, fontWeight: w, height: size == MpText.title ? 1.4 : (size == MpText.meta ? 1.38 : 1.47), color: color ?? MpColors.of(c).text);

/// Motion: one place for durations/curves. Zero when "Reduce motion" is on.
class Motion {
  static bool reduce = false;
  static const curve = Curves.easeOutCubic;
  static const pop = Curves.easeOutBack;
  static Duration d(int ms) => reduce ? Duration.zero : Duration(milliseconds: ms);
}

/// Icon paths from the design (24 grid, 1.6 stroke, round caps).
const icons = {
  'phone': 'M9.5 2.5h5a2.5 2.5 0 0 1 2.5 2.5v14a2.5 2.5 0 0 1-2.5 2.5h-5A2.5 2.5 0 0 1 7 19V5a2.5 2.5 0 0 1 2.5-2.5zM11 18.5h2',
  'laptop': 'M6 5h12a1.5 1.5 0 0 1 1.5 1.5V15h-15V6.5A1.5 1.5 0 0 1 6 5zM2.5 18.5h19',
  'desktop': 'M4.5 4h15A1.5 1.5 0 0 1 21 5.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 14.5v-9A1.5 1.5 0 0 1 4.5 4zM9 20h6M12 16v4',
  'tablet': 'M7 3h10a2.5 2.5 0 0 1 2.5 2.5v13A2.5 2.5 0 0 1 17 21H7a2.5 2.5 0 0 1-2.5-2.5v-13A2.5 2.5 0 0 1 7 3zM11 18h2',
  'add': 'M12 5v14M5 12h14',
  'back': 'M15 5l-7 7 7 7',
  'attach': 'M20 11.5l-8.2 8.2a5 5 0 0 1-7.1-7.1l8.5-8.5a3.3 3.3 0 0 1 4.7 4.7l-8.5 8.5a1.7 1.7 0 0 1-2.4-2.4l7.8-7.8',
  'send': 'M5 12h14M13 6l6 6-6 6',
  'file': 'M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8zM14 3v5h5',
  'image': 'M5.5 4.5h13a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2v-11a2 2 0 0 1 2-2zM20.5 15.5l-5-5-9 9M9 8.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z',
  'reply': 'M10 8l-5 4 5 4M5 12h9a5 5 0 0 1 5 5v1',
  'copy': 'M10.5 8.5h7a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-7a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2zM15.5 8.5v-2a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h2',
  'delete': 'M4.5 7h15M10 4h4M6.5 7l.8 11.5A2 2 0 0 0 9.3 20h5.4a2 2 0 0 0 2-1.5L17.5 7',
  'info': 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17zM12 11v5M12 8h.01',
  'battery': 'M5 7.5h12a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2zM21.5 10.5v3',
  'screen': 'M2.5 12S6 6 12 6s9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6zM12 9.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z',
  'remote': 'M5.5 4.5l13 5.2-5.6 1.9-1.9 5.6z',
  'assistant': 'M12 3c.8 4.8 4.2 8.2 9 9-4.8.8-8.2 4.2-9 9-.8-4.8-4.2-8.2-9-9 4.8-.8 8.2-4.2 9-9z',
  'close': 'M6 6l12 12M18 6L6 18',
  'search': 'M11 4.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM20 20l-4.4-4.4',
  'check': 'M5 12.5l4.5 4.5L19 7.5',
  'error': 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17zM12 7.5v5.5M12 16h.01',
  'folder': 'M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z',
  'save': 'M12 4v11M7 10l5 5 5-5M5 20h14',
  'drop': 'M12 20V9M7 14l5-5 5 5M5 4h14',
  'settings': 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
};

class MpIcon extends StatelessWidget {
  final String name;
  final double size, stroke;
  final Color? color;
  const MpIcon(this.name, {super.key, this.size = 24, this.stroke = 1.6, this.color});
  @override
  Widget build(BuildContext context) {
    final col = color ?? DefaultTextStyle.of(context).style.color ?? MpColors.of(context).text;
    return SvgPicture.string(
      '<svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="$stroke" stroke-linecap="round" stroke-linejoin="round"><path d="${icons[name]}"/></svg>',
      width: size, height: size, colorFilter: ColorFilter.mode(col, BlendMode.srcIn),
    );
  }
}

import 'dart:typed_data';
import 'package:flutter/material.dart';

/// Colours and type, close to the iPhone app's dark "aero" look.
class AppTheme {
  static const bgTop = Color(0xFF1B2440);
  static const bgBottom = Color(0xFF0E1222);
  static const accent = Color(0xFFFF5C9A);
  static const lime = Color(0xFF8BD450);
  static const amber = Color(0xFFF2B33D);
  static const danger = Color(0xFFFF5A5A);
  static const title = Colors.white;
  static const subtitle = Color(0xFFB8C0DA);

  static ThemeData get data => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: bgBottom,
    cardTheme: CardThemeData(
      color: Colors.white.withValues(alpha: 0.07),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    ),
  );

  static Color rgb(int v) => Color(0xFF000000 | (v & 0xFFFFFF));

  static const palette = [
    0xFF4081,
    0xFF5A5A,
    0xFF9F40,
    0xF2D53C,
    0x8BD450,
    0x3CD2B4,
    0x40B8FF,
    0x5A6CFF,
    0xA25AFF,
    0xFFFFFF,
  ];
}

/// A rounded translucent card, like the iPhone app's glass panels.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
    ),
    child: child,
  );
}

/// A circular photo, or the first letter on the person's colour.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    required this.color,
    this.photo,
    this.size = 44,
    this.online,
  });
  final String name;
  final int color;
  final List<int>? photo;
  final double size;
  final bool? online;
  @override
  Widget build(BuildContext context) {
    final c = AppTheme.rgb(color);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c, width: 2.5),
            color: c.withValues(alpha: 0.35),
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: photo != null
              ? Image.memory(
                  asBytes(photo!),
                  fit: BoxFit.cover,
                  width: size,
                  height: size,
                )
              : Text(
                  name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                  style: TextStyle(
                    fontSize: size * 0.42,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
        ),
        if (online == true)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: size * 0.26,
              height: size * 0.26,
              decoration: BoxDecoration(
                color: AppTheme.lime,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.bgBottom, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

// Image.memory wants a Uint8List.
Uint8List asBytes(List<int> bytes) =>
    bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

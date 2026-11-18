import 'package:flutter/material.dart';
const _teal = Color(0xFF0B7A8A);
ThemeData amerTheme(Brightness b) => ThemeData(
  useMaterial3: true, brightness: b,
  colorScheme: ColorScheme.fromSeed(seedColor: _teal, brightness: b),
  fontFamily: 'Manrope',
);

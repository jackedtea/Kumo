// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The page colours a book is read in.
enum ReaderTheme {
  /// The app's own light or dark.
  system,
  light,
  sepia,
  dark,
  black;

  /// Paper and ink for this theme under the app's [brightness].
  ({Color background, Color foreground, Color link}) colours(
    Brightness brightness,
  ) {
    final resolved = this == system
        ? (brightness == Brightness.dark ? dark : light)
        : this;
    return switch (resolved) {
      ReaderTheme.sepia => (
        background: const Color(0xFFF4ECD8),
        foreground: const Color(0xFF3B2F22),
        link: const Color(0xFF8A4B12),
      ),
      ReaderTheme.dark => (
        background: const Color(0xFF1E1F22),
        foreground: const Color(0xFFDCDCDC),
        link: const Color(0xFF8AB4F8),
      ),
      ReaderTheme.black => (
        background: const Color(0xFF000000),
        foreground: const Color(0xFFC8C8C8),
        link: const Color(0xFF8AB4F8),
      ),
      _ => (
        background: const Color(0xFFFFFFFF),
        foreground: const Color(0xFF1B1B1B),
        link: const Color(0xFF1A5FB4),
      ),
    };
  }
}

/// How books are read on this device.
///
/// Device-local UI choices, like the grid size: a font size right for a
/// phone held close is wrong for a television across the room.
@immutable
class ReaderSettings {
  const ReaderSettings({
    this.theme = ReaderTheme.system,
    this.fontScale = 100,
    this.lineHeight = 1.5,
    this.margin = 6,
    this.scrolled = false,
    this.justify = true,
    this.comicRightToLeft = false,
    this.comicSpread = true,
  });

  final ReaderTheme theme;

  /// Percent of the book's own size, 70..200.
  final int fontScale;
  final double lineHeight;

  /// Percent of the page width given to each side margin.
  final int margin;

  /// One long column instead of pages.
  final bool scrolled;
  final bool justify;

  /// Manga order: the next page is to the left.
  final bool comicRightToLeft;

  /// Two pages side by side on a wide landscape screen.
  final bool comicSpread;

  static const minFont = 70;
  static const maxFont = 200;

  ReaderSettings copyWith({
    ReaderTheme? theme,
    int? fontScale,
    double? lineHeight,
    int? margin,
    bool? scrolled,
    bool? justify,
    bool? comicRightToLeft,
    bool? comicSpread,
  }) => ReaderSettings(
    theme: theme ?? this.theme,
    fontScale: (fontScale ?? this.fontScale).clamp(minFont, maxFont),
    lineHeight: (lineHeight ?? this.lineHeight).clamp(1.0, 2.4),
    margin: (margin ?? this.margin).clamp(0, 20),
    scrolled: scrolled ?? this.scrolled,
    justify: justify ?? this.justify,
    comicRightToLeft: comicRightToLeft ?? this.comicRightToLeft,
    comicSpread: comicSpread ?? this.comicSpread,
  );

  Map<String, Object> toJson() => <String, Object>{
    'theme': theme.name,
    'fontScale': fontScale,
    'lineHeight': lineHeight,
    'margin': margin,
    'scrolled': scrolled,
    'justify': justify,
    'comicRightToLeft': comicRightToLeft,
    'comicSpread': comicSpread,
  };

  static ReaderSettings fromJson(Object? json) {
    const d = ReaderSettings();
    if (json is! Map) return d;
    T read<T>(String key, T fallback) {
      final v = json[key];
      return v is T ? v : fallback;
    }

    return d.copyWith(
      theme: ReaderTheme.values.asNameMap()[json['theme']] ?? d.theme,
      fontScale: read<num>('fontScale', d.fontScale).toInt(),
      lineHeight: read<num>('lineHeight', d.lineHeight).toDouble(),
      margin: read<num>('margin', d.margin).toInt(),
      scrolled: read<bool>('scrolled', d.scrolled),
      justify: read<bool>('justify', d.justify),
      comicRightToLeft: read<bool>('comicRightToLeft', d.comicRightToLeft),
      comicSpread: read<bool>('comicSpread', d.comicSpread),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderSettings &&
      other.theme == theme &&
      other.fontScale == fontScale &&
      other.lineHeight == lineHeight &&
      other.margin == margin &&
      other.scrolled == scrolled &&
      other.justify == justify &&
      other.comicRightToLeft == comicRightToLeft &&
      other.comicSpread == comicSpread;

  @override
  int get hashCode => Object.hash(
    theme,
    fontScale,
    lineHeight,
    margin,
    scrolled,
    justify,
    comicRightToLeft,
    comicSpread,
  );
}

final readerSettingsProvider =
    NotifierProvider<ReaderSettingsController, ReaderSettings>(
      ReaderSettingsController.new,
    );

class ReaderSettingsController extends Notifier<ReaderSettings> {
  static const _key = 'reader_settings_v1';

  @override
  ReaderSettings build() {
    Future<void>.microtask(_restore);
    return const ReaderSettings();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (!ref.mounted || raw == null) return;
      state = ReaderSettings.fromJson(jsonDecode(raw));
    } on Object catch (e) {
      debugPrint('Could not read the reader settings: $e');
    }
  }

  Future<void> update(ReaderSettings Function(ReaderSettings) change) async {
    state = change(state);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(state.toJson()));
    } on Object catch (e) {
      debugPrint('Could not save the reader settings: $e');
    }
  }
}

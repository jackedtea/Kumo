// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kumo/app/app.dart';
import 'package:kumo/app/router.dart';
import 'package:kumo/features/player/subtitle_fonts.dart';
import 'package:kumo/features/settings/player_settings.dart';

Future<ProviderContainer> _openSubtitleSettings(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(400, 900);
  addTearDown(tester.view.reset);

  final container = ProviderContainer();
  addTearDown(container.dispose);
  final router = buildRouter();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: KumoApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  router.go('/settings/subtitle');
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled face and its notice is in the bundle', () async {
    for (final BundledSubtitleFont f in bundledSubtitleFonts) {
      final data = await rootBundle.load(f.asset);
      expect(data.lengthInBytes, greaterThan(10000), reason: f.asset);
      final license = f.license;
      if (license != null) {
        expect(await rootBundle.loadString(license), contains('Open Font'));
      }
    }
  });

  test('Roboto unless chosen, and a blank name falls back to it', () {
    expect(const PlayerSettings().subtitleFont, 'Roboto');
    final saved = const PlayerSettings(subtitleFont: 'Lora').toJson();
    expect(PlayerSettings.fromJson(saved).subtitleFont, 'Lora');
    expect(
      PlayerSettings.fromJson(<String, dynamic>{'subtitleFont': '  '})
          .subtitleFont,
      'Roboto',
    );
  });

  testWidgets('picking a bundled face saves it', (tester) async {
    final container = await _openSubtitleSettings(tester);

    await tester.tap(find.text('Font'));
    await tester.pumpAndSettle();
    for (final BundledSubtitleFont f in bundledSubtitleFonts) {
      expect(find.text(f.family), findsWidgets);
    }

    await tester.tap(find.text('Lora').last);
    await tester.pumpAndSettle();

    expect(container.read(playerSettingsProvider).subtitleFont, 'Lora');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a desktop can name an installed font', (tester) async {
    final container = await _openSubtitleSettings(tester);

    await tester.tap(find.text('Font'));
    await tester.pumpAndSettle();

    final other = find.text('Installed font…');
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      expect(other, findsNothing);
      return;
    }

    await tester.tap(other);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Segoe UI ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(container.read(playerSettingsProvider).subtitleFont, 'Segoe UI');
  });
}

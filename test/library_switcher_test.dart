// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_library_source.dart';

import 'package:kumo/app/app.dart';
import 'package:kumo/app/router.dart';
import 'package:kumo/features/servers/server_library.dart';
import 'package:kumo/servers/media_library_source.dart';

class _Server extends FakeLibrarySource {
  const _Server();

  @override
  Future<List<LibraryView>> views() async => const <LibraryView>[
    LibraryView(id: 'v1', name: 'Films', kind: 'movies'),
    LibraryView(id: 'v2', name: 'Shows', kind: 'tvshows'),
  ];
}

Future<GoRouter> _pump(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.reset);

  final router = buildRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [activeServerProvider.overrideWithValue(const _Server())],
      child: KumoApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _tapTab(WidgetTester tester, IconData icon, IconData selected) {
  final bar = find.byType(NavigationBar);
  final either = find.descendant(
    of: bar,
    matching: find.byWidgetPredicate(
      (w) => w is Icon && (w.icon == icon || w.icon == selected),
    ),
  );
  return tester.tap(either.first).then((_) => tester.pumpAndSettle());
}

Future<void> _tapLibraries(WidgetTester tester) => _tapTab(
  tester,
  Icons.video_library_outlined,
  Icons.video_library_rounded,
);

final _sheet = find.byType(BottomSheet);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('tapping Libraries again keeps the one switcher open', (
    tester,
  ) async {
    await _pump(tester);
    await _tapLibraries(tester);
    expect(_sheet, findsNothing);

    await _tapLibraries(tester);
    expect(_sheet, findsOneWidget);

    await _tapLibraries(tester);
    await _tapLibraries(tester);
    expect(_sheet, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another tab closes the switcher', (tester) async {
    final router = await _pump(tester);
    await _tapLibraries(tester);
    await _tapLibraries(tester);
    expect(_sheet, findsOneWidget);

    await _tapTab(tester, Icons.settings_outlined, Icons.settings_rounded);
    expect(router.state.uri.path, '/settings');
    expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);

    await _tapLibraries(tester);
    expect(router.state.uri.path, '/libraries');
    expect(_sheet, findsNothing);

    // And it opens again afterwards: nothing still thinks it is up.
    await _tapLibraries(tester);
    expect(_sheet, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

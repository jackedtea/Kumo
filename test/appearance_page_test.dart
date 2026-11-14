// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kumo/app/app.dart';
import 'package:kumo/app/router.dart';

Future<void> _openAppearance(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(400, 800);
  addTearDown(tester.view.reset);

  final router = buildRouter();
  await tester.pumpWidget(ProviderScope(child: KumoApp(router: router)));
  await tester.pumpAndSettle();
  router.go('/settings/appearance');
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('each theme card draws its preview at a real size',
      (tester) async {
    await _openAppearance(tester);

    // The previews were bare ColoredBoxes once, which with no child are 0×0:
    // three empty cards with a label under each.
    final boxes = tester
        .renderObjectList<RenderBox>(find.byType(ColoredBox))
        .where((box) => box.size.width >= 30 && box.size.height >= 30);
    // Light, dark, and the two halves of System.
    expect(boxes.length, greaterThanOrEqualTo(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('no rows that only say they are not done', (tester) async {
    await _openAppearance(tester);

    expect(find.text('Default library view'), findsNothing);
    expect(find.text('Density'), findsNothing);
    expect(find.text('Layout'), findsNothing);
  });
}

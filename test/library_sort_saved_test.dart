// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_library_source.dart';

import 'package:kumo/app/app.dart';
import 'package:kumo/app/router.dart';
import 'package:kumo/features/servers/server_library.dart';
import 'package:kumo/servers/media_library_source.dart';

/// A library whose grid says which sort it was asked for, and whose saved
/// sort lives here.
class _Server extends FakeLibrarySource {
  _Server(this.saved);

  ({ServerSort sort, SortOrder? order})? saved;
  final List<ServerSort> asked = <ServerSort>[];

  @override
  Future<List<LibraryView>> views() async => const <LibraryView>[
    LibraryView(id: 'v1', name: 'Films', kind: 'movies'),
  ];

  @override
  Future<({ServerSort sort, SortOrder? order})?> librarySort(
    String viewId,
  ) async =>
      saved;

  @override
  Future<void> setLibrarySort(
    String viewId,
    ServerSort sort,
    SortOrder? order,
  ) async {
    saved = (sort: sort, order: order);
  }

  @override
  Future<List<ServerItem>> items(
    String viewId, {
    int startIndex = 0,
    int limit = 100,
    ServerSort sort = ServerSort.name,
    SortOrder? order,
    LibraryFilter filter = LibraryFilter.none,
    bool groupCollections = false,
  }) async {
    asked.add(sort);
    return <ServerItem>[
      ServerItem(id: 'm1', title: 'Sorted by ${sort.name}',
          kind: ServerItemKind.movie),
    ];
  }
}

Future<void> _pump(WidgetTester tester, MediaLibrarySource server) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(600, 1000);
  addTearDown(tester.view.reset);

  final router = buildRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [activeServerProvider.overrideWithValue(server)],
      child: KumoApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  router.push('/library', extra: 'v1');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a library opens on the sort the server saved, only', (
    tester,
  ) async {
    final server = _Server((sort: ServerSort.dateAdded, order: null));
    await _pump(tester, server);

    expect(find.text('Sorted by dateAdded'), findsOneWidget);
    // Waited for: the grid is never fetched by name first.
    expect(server.asked, isNot(contains(ServerSort.name)));
  });

  testWidgets('with nothing saved it opens by name', (tester) async {
    final server = _Server(null);
    await _pump(tester, server);

    expect(find.text('Sorted by name'), findsOneWidget);
  });
}

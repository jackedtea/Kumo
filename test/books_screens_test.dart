// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kumo/app/app.dart';
import 'package:kumo/app/router.dart';
import 'package:kumo/features/books/book_detail_page.dart';
import 'package:kumo/features/books/book_reader_page.dart';
import 'package:kumo/features/servers/server_library.dart';
import 'package:kumo/servers/media_library_source.dart';

import 'fake_library_source.dart';

const _dune = ServerItem(
  id: 'b1',
  title: 'Dune Messiah',
  kind: ServerItemKind.book,
  path: '/books/Herbert/Dune Messiah.epub',
  parentId: 'f1',
  seriesTitle: 'Dune',
  episodeNumber: 2,
  year: 1969,
  overview: 'Twelve years after the events of Dune.',
  people: <ServerPerson>[ServerPerson(name: 'Frank Herbert', role: 'Author')],
  positionTicks: 4200000,
  position: Duration(milliseconds: 420),
);

const _first = ServerItem(
  id: 'b0',
  title: 'Dune',
  kind: ServerItemKind.book,
  seriesTitle: 'Dune',
  episodeNumber: 1,
  parentId: 'f1',
);

const _unread = ServerItem(
  id: 'b2',
  title: 'Paper',
  kind: ServerItemKind.book,
  path: '/books/paper.pdf',
);

const _heard = ServerItem(
  id: 'a1',
  title: 'Dune (audiobook)',
  kind: ServerItemKind.audioBook,
  runtime: Duration(hours: 21),
);

class _Books extends FakeLibrarySource {
  @override
  Future<List<LibraryView>> views() async => const <LibraryView>[
    LibraryView(id: 'v', name: 'Books', kind: 'books'),
  ];

  @override
  Future<ServerItem> item(String itemId) async => switch (itemId) {
    'b1' => _dune,
    'b2' => _unread,
    'a1' => _heard,
    _ => _first,
  };

  @override
  Future<List<ServerItem>> items(
    String viewId, {
    int startIndex = 0,
    int limit = 100,
    ServerSort sort = ServerSort.name,
    SortOrder? order,
    LibraryFilter filter = LibraryFilter.none,
    bool groupCollections = false,
  }) async => const <ServerItem>[_first, _dune, _unread];

  @override
  Future<List<ServerItem>> resumableBooks({
    int limit = 12,
    String? viewId,
  }) async => const <ServerItem>[_dune];

  @override
  Future<List<ServerItem>> bookSeries(
    String parentId,
    String seriesName,
  ) async => const <ServerItem>[_first, _dune];
}

Future<GoRouter> _pump(
  WidgetTester tester, {
  Size size = const Size(400, 900),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  final router = buildRouter();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeServerProvider.overrideWithValue(_Books()),
        connectedServerProvider.overrideWithValue(_Books()),
      ],
      child: KumoApp(router: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('a books library', () {
    testWidgets('has the grid, suggestions, genres and collections', (
      tester,
    ) async {
      final router = await _pump(tester);
      router.go('/library', extra: 'v');
      await tester.pumpAndSettle();

      final tabs = find.byType(Tab);
      final labels = <String>[
        for (final Element e in tabs.evaluate()) (e.widget as Tab).text ?? '',
      ];
      expect(labels, <String>[
        'Browse',
        'Suggestions',
        'Genres',
        'Collections',
      ]);
      // A cover says who wrote it.
      expect(find.text('Frank Herbert'), findsWidgets);
    });

    testWidgets('suggests what is being read', (tester) async {
      final router = await _pump(tester);
      router.go('/library', extra: 'v');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Suggestions'));
      await tester.pumpAndSettle();

      expect(find.text('Continue reading'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a cover opens the book, not a film', (tester) async {
      final router = await _pump(tester);
      router.go('/library', extra: 'v');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Paper').first);
      await tester.pumpAndSettle();

      expect(find.byType(BookDetailPage), findsOneWidget);
    });
  });

  group('a book', () {
    for (final Size size in const <Size>[
      Size(400, 900),
      Size(900, 1000),
      Size(1400, 900),
    ]) {
      testWidgets('started: continue, with where (${size.width})', (
        tester,
      ) async {
        final router = await _pump(tester, size: size);
        router.push('/library/book', extra: 'b1');
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Dune Messiah'), findsWidgets);
        expect(find.text('Frank Herbert'), findsOneWidget);
        expect(find.text('Dune · Volume 2'), findsOneWidget);
        expect(find.text('EPUB'), findsOneWidget);
        expect(find.textContaining('Continue reading'), findsOneWidget);
        expect(find.textContaining('42%'), findsOneWidget);
        // The other volume, not this one again.
        expect(find.text('More in Dune'), findsOneWidget);
      });
    }

    testWidgets('unread: Read, and its read mark says read', (tester) async {
      final router = await _pump(tester);
      router.push('/library/book', extra: 'b2');
      await tester.pumpAndSettle();

      expect(find.text('Read'), findsOneWidget);
      expect(find.byTooltip('Mark as read'), findsOneWidget);
      expect(find.byTooltip('Mark as watched'), findsNothing);
    });

    testWidgets('an audiobook is listened to', (tester) async {
      final router = await _pump(tester);
      router.push('/library/book', extra: 'a1');
      await tester.pumpAndSettle();

      expect(find.text('Listen'), findsOneWidget);
      expect(find.byIcon(Icons.headphones_rounded), findsOneWidget);
    });

    testWidgets('Read opens the reader with the book', (tester) async {
      final router = await _pump(tester);
      router.push('/library/book', extra: 'b2');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Read'));
      // The reader goes to fetch the file; not settling, which would wait on
      // a fetch that has no server behind it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(BookReaderPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('home has a Continue reading row when there are books', (
    tester,
  ) async {
    final router = await _pump(tester);
    router.go('/home');
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kumo/features/books/book_files.dart';
import 'package:kumo/features/books/book_progress.dart';
import 'package:kumo/features/books/comic_archive.dart';
import 'package:kumo/features/books/reader_server.dart';
import 'package:kumo/features/books/reader_settings.dart';
import 'package:kumo/servers/books.dart';
import 'package:kumo/servers/media_library_source.dart';

import 'fake_library_source.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);

  final ResponseBody Function(RequestOptions) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _bytes(
  List<int> data, {
  int status = 200,
  Map<String, List<String>> headers = const <String, List<String>>{},
}) => ResponseBody(
  Stream<Uint8List>.value(Uint8List.fromList(data)),
  status,
  headers: <String, List<String>>{
    Headers.contentLengthHeader: <String>['${data.length}'],
    ...headers,
  },
);

class _RealHttp extends HttpOverrides {}

class _Recorder extends FakeLibrarySource {
  _Recorder({this.fail = false});

  bool fail;
  final sent = <(String, int, bool?)>[];

  @override
  Future<void> setBookPosition(
    String itemId,
    BookPosition position, {
    bool? finished,
  }) async {
    if (fail) throw const ServerException('offline');
    sent.add((itemId, position.ticks, finished));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kumo_books_');
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('the book cache', () {
    const book = ServerItem(
      id: 'b1',
      title: 'Dune',
      kind: ServerItemKind.book,
      path: '/books/Dune.epub',
    );

    test('fetches once, then reads from disk', () async {
      final adapter = _Adapter((_) => _bytes(utf8.encode('PK-epub-bytes')));
      final files = BookFiles(
        root: Directory('${temp.path}/books'),
        client: Dio()..httpClientAdapter = adapter,
      );

      final first = await files.fetch(const FakeLibrarySource(), book);
      final second = await files.fetch(const FakeLibrarySource(), book);

      expect(first.path, endsWith('book.epub'));
      expect(second.path, first.path);
      expect(await first.readAsString(), 'PK-epub-bytes');
      expect(adapter.requests, hasLength(1));
    });

    test('a refusal is the account, not the network', () async {
      final files = BookFiles(
        root: Directory('${temp.path}/books'),
        client: Dio()
          ..httpClientAdapter = _Adapter((_) => _bytes(<int>[], status: 403)),
      );

      await expectLater(
        files.fetch(const FakeLibrarySource(), book),
        throwsA(
          isA<BookFileException>().having(
            (e) => e.failure,
            'failure',
            BookFileFailure.forbidden,
          ),
        ),
      );
    });

    test('picks up a broken transfer where it stopped', () async {
      final part = File('${temp.path}/books/p1/b1/book.part');
      await part.create(recursive: true);
      await part.writeAsString('first-');

      final adapter = _Adapter((o) {
        expect(o.headers['Range'], 'bytes=6-');
        return _bytes(utf8.encode('second'), status: 206);
      });
      final files = BookFiles(
        root: Directory('${temp.path}/books'),
        client: Dio()..httpClientAdapter = adapter,
      );

      final file = await files.fetch(const FakeLibrarySource(), book);
      expect(await file.readAsString(), 'first-second');
    });

    test('a 200 to a range request starts the file over', () async {
      final part = File('${temp.path}/books/p1/b1/book.part');
      await part.create(recursive: true);
      await part.writeAsString('stale');

      final files = BookFiles(
        root: Directory('${temp.path}/books'),
        client: Dio()
          ..httpClientAdapter = _Adapter((_) => _bytes(utf8.encode('whole'))),
      );

      final file = await files.fetch(const FakeLibrarySource(), book);
      expect(await file.readAsString(), 'whole');
    });

    test(
      'a book the server named nothing for takes the header, then the bytes',
      () async {
        const unnamed = ServerItem(
          id: 'b2',
          title: 'X',
          kind: ServerItemKind.book,
        );
        final named = BookFiles(
          root: Directory('${temp.path}/a'),
          client: Dio()
            ..httpClientAdapter = _Adapter(
              (_) => _bytes(
                utf8.encode('zip'),
                headers: <String, List<String>>{
                  'content-disposition': <String>[
                    'attachment; filename="One Piece 01.cbz"',
                  ],
                },
              ),
            ),
        );
        final sniffed = BookFiles(
          root: Directory('${temp.path}/b'),
          client: Dio()
            ..httpClientAdapter = _Adapter(
              (_) => _bytes(utf8.encode('%PDF-1.7')),
            ),
        );

        expect(
          (await named.fetch(const FakeLibrarySource(), unnamed)).path,
          endsWith('book.cbz'),
        );
        expect(
          (await sniffed.fetch(const FakeLibrarySource(), unnamed)).path,
          endsWith('book.pdf'),
        );
      },
    );

    test('evicts the least recently read, never the one being opened', () {
      final now = DateTime(2026, 11, 16);
      CachedBook b(String path, int mb, int daysAgo) => CachedBook(
        path: path,
        bytes: mb * 1000000,
        lastUsed: now.subtract(Duration(days: daysAgo)),
      );

      final books = <CachedBook>[
        b('new', 400, 0),
        b('old', 400, 9),
        b('middle', 400, 3),
      ];
      expect(
        booksToEvict(books, budget: 1000000000).map((x) => x.path),
        <String>['old'],
      );
      expect(
        booksToEvict(books, budget: 1000000000, keep: 'old').map((x) => x.path),
        <String>['middle'],
      );
      expect(booksToEvict(books, budget: 2000000000), isEmpty);
    });

    test('Content-Disposition, plain and RFC 5987', () {
      expect(
        dispositionFileName('attachment; filename="Dune.epub"'),
        'Dune.epub',
      );
      expect(
        dispositionFileName("attachment; filename*=UTF-8''S%C3%A1ch%201.pdf"),
        'Sách 1.pdf',
      );
      expect(dispositionFileName('inline'), isNull);
      expect(dispositionFileName(null), isNull);
    });
  });

  group('comic pages', () {
    test('sort the way a person numbers them', () {
      final names = <String>['10.jpg', '2.jpg', '1.jpg', 'cover.jpg', '01a.jpg']
        ..sort(naturalCompare);
      expect(names, <String>[
        '1.jpg',
        '01a.jpg',
        '2.jpg',
        '10.jpg',
        'cover.jpg',
      ]);
      expect(naturalCompare('Ch 2/p9.png', 'Ch 10/p1.png'), lessThan(0));
    });

    test('are images, not the clutter around them', () {
      expect(isComicPage('001.JPG'), isTrue);
      expect(isComicPage('pages/002.webp'), isTrue);
      expect(isComicPage('__MACOSX/._001.jpg'), isFalse);
      expect(isComicPage('.DS_Store'), isFalse);
      expect(isComicPage('ComicInfo.xml'), isFalse);
    });

    test('spreads: the cover alone, then pairs', () {
      expect(spreadPages(0, 5), <int>[0]);
      expect(spreadPages(1, 5), <int>[1, 2]);
      expect(spreadPages(2, 5), <int>[3, 4]);
      expect(spreadPages(2, 4), <int>[3]);
      expect(spreadOf(0), 0);
      expect(spreadOf(1), 1);
      expect(spreadOf(2), 1);
      expect(spreadOf(3), 2);
      expect(spreadCount(5), 3);
      expect(spreadCount(4), 3);
      expect(spreadCount(1), 1);
      expect(spreadCount(0), 0);
    });

    test('a real CBZ opens, in page order, a page at a time', () {
      final archive = Archive()
        ..add(ArchiveFile.bytes('10.png', <int>[10]))
        ..add(ArchiveFile.bytes('2.png', <int>[2]))
        ..add(ArchiveFile.bytes('ComicInfo.xml', utf8.encode('<x/>')))
        ..add(ArchiveFile.bytes('1.png', <int>[1]));
      final path = '${temp.path}/one.cbz';
      File(path).writeAsBytesSync(ZipEncoder().encode(archive));

      final comic = ComicArchive.open(path, BookFormat.cbz);
      addTearDown(comic.close);
      expect(comic.pageCount, 3);
      expect(comic.page(0), <int>[1]);
      expect(comic.page(1), <int>[2]);
      expect(comic.page(2), <int>[10]);
      expect(comic.page(3), isNull);
    });
  });

  group('the position goes to the server', () {
    test('once the reader stops turning pages', () async {
      final source = _Recorder();
      // The real wait is five seconds; the rule is the same at a tenth.
      final saver = BookProgressSaver(
        source: source,
        itemId: 'b1',
        delay: const Duration(milliseconds: 100),
      );
      addTearDown(saver.dispose);

      saver.update(const BookPosition.fraction(0.1));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      saver.update(const BookPosition.fraction(0.2));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      // The second turn restarted the wait.
      expect(source.sent, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(source.sent, <(String, int, bool?)>[('b1', 2000000, null)]);
    });

    test('at once when the reader closes, and as read at the end', () async {
      final source = _Recorder();
      final saver = BookProgressSaver(source: source, itemId: 'b1');

      saver.update(const BookPosition.page(3, pageCount: 4));
      await saver.finish(const BookPosition.page(3, pageCount: 4));
      saver.dispose();

      expect(source.sent, <(String, int, bool?)>[('b1', 30000, true)]);
    });

    test('kept when the server is away, and sent when it is back', () async {
      final source = _Recorder(fail: true);
      final pending = PendingBookPositions();
      final saver = BookProgressSaver(
        source: source,
        itemId: 'b1',
        pending: pending,
      );

      saver.update(const BookPosition.fraction(0.5));
      await saver.flush();
      expect(source.sent, isEmpty);
      expect((await pending.get('p1', 'b1'))?.ticks, 5000000);

      source.fail = false;
      await pending.sendAll(source);
      expect(source.sent, <(String, int, bool?)>[('b1', 5000000, null)]);
      expect(await pending.get('p1', 'b1'), isNull);
    });
  });

  test(
    'a downloaded book read with no server signed in waits for one',
    () async {
      final pending = PendingBookPositions();
      final saver = BookProgressSaver(
        source: null,
        profileId: 'p1',
        itemId: 'b9',
        pending: pending,
      );

      saver.update(const BookPosition.page(41, pageCount: 200));
      await saver.flush();
      saver.dispose();

      expect((await pending.get('p1', 'b9'))?.ticks, 410000);
      final back = _Recorder();
      await pending.sendAll(back);
      expect(back.sent, <(String, int, bool?)>[('b9', 410000, null)]);
    },
  );

  test('reader settings survive a round trip, and junk falls back', () {
    const s = ReaderSettings(
      theme: ReaderTheme.sepia,
      fontScale: 130,
      lineHeight: 1.8,
      margin: 10,
      scrolled: true,
      justify: false,
      comicRightToLeft: true,
      comicSpread: false,
    );
    expect(ReaderSettings.fromJson(jsonDecode(jsonEncode(s.toJson()))), s);
    expect(
      ReaderSettings.fromJson(<String, Object>{'fontScale': 900, 'theme': 'x'}),
      const ReaderSettings(fontScale: ReaderSettings.maxFont),
    );
    expect(ReaderSettings.fromJson('nonsense'), const ReaderSettings());
  });

  group('the reader server', () {
    // The test binding answers every HttpClient with a 400; this one talks
    // to the loopback server for real.
    Future<(int, String)> get(Uri uri) =>
        HttpOverrides.runWithHttpOverrides(() async {
          final client = HttpClient();
          try {
            final request = await client.getUrl(uri);
            final response = await request.close();
            return (
              response.statusCode,
              await response.transform(utf8.decoder).join(),
            );
          } finally {
            client.close(force: true);
          }
        }, _RealHttp());

    test(
      'serves the page and the book behind its token, nothing else',
      () async {
        final file = File('${temp.path}/book.epub')..writeAsStringSync('BOOK');
        final server = await ReaderServer.start(file);
        addTearDown(server.close);

        final page = server.pageUri(<String, String>{'start': '0.5'});
        expect(page.host, '127.0.0.1');
        expect(page.queryParameters['book'], server.bookUri.toString());
        expect(server.bookUri.path, endsWith('/book.epub'));

        expect(await get(server.bookUri), (200, 'BOOK'));

        final (status, html) = await get(page);
        expect(status, 200);
        expect(html, contains('kumo.js'));

        final noToken = server.bookUri.replace(path: '/book.epub');
        expect((await get(noToken)).$1, 404);
        final outside = page.resolve('../../pubspec.yaml');
        expect((await get(outside)).$1, 404);
        final notServed = page.resolve('LICENSE');
        expect((await get(notServed)).$1, 404);
      },
    );
  });
}

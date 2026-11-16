// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kumo/servers/books.dart';
import 'package:kumo/servers/jellyfin_dto.dart';
import 'package:kumo/servers/jellyfin_source.dart';
import 'package:kumo/servers/media_library_source.dart';
import 'package:kumo/servers/server_profile.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final List<RequestOptions> requests = <RequestOptions>[];

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

ResponseBody _json(Object body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: <String, List<String>>{
    Headers.contentTypeHeader: <String>[Headers.jsonContentType],
  },
);

(JellyfinSource, _FakeAdapter) _source(
  ResponseBody Function(RequestOptions) handler,
) {
  final adapter = _FakeAdapter(handler);
  final dio = Dio(BaseOptions(validateStatus: (_) => true))
    ..httpClientAdapter = adapter;
  return (
    JellyfinSource(
      profile: const ServerProfile(
        id: 'p1',
        name: 'Home',
        uri: 'https://media.home.lan',
        userId: 'u1',
        username: 'nam',
      ),
      token: 'tok',
      identity: const ClientIdentity(deviceId: 'dev1', deviceName: 'Test'),
      client: dio,
    ),
    adapter,
  );
}

void main() {
  group('the position, in jellyfin-web\'s encoding', () {
    // The numbers here are the web client's, not this app's: its EPUB player
    // reports `fraction × 1000` as a time in milliseconds and its PDF and
    // comic players report the page, and the server stores time × 10 000.

    test('half way through an EPUB is five million ticks', () {
      expect(const BookPosition.fraction(0.5).ticks, 5000000);
      expect(const BookPosition.fraction(1).ticks, 10000000);
      expect(const BookPosition.fraction(0.1234567).ticks, 1234567);
    });

    test('a page is ten thousand ticks, counted from zero', () {
      expect(const BookPosition.page(0).ticks, 0);
      expect(const BookPosition.page(1).ticks, 10000);
      expect(const BookPosition.page(119).ticks, 1190000);
    });

    test('reads back what it wrote', () {
      expect(
        BookPosition.fromTicks(5000000, BookFamily.reflowable),
        const BookPosition.fraction(0.5),
      );
      expect(
        BookPosition.fromTicks(1190000, BookFamily.pdf, pageCount: 300),
        const BookPosition.page(119, pageCount: 300),
      );
      expect(
        BookPosition.fromTicks(40000, BookFamily.comic),
        const BookPosition.page(4),
      );
    });

    test('nothing stored is not a position', () {
      expect(BookPosition.fromTicks(null, BookFamily.reflowable), isNull);
      expect(BookPosition.fromTicks(0, BookFamily.pdf), isNull);
      expect(BookPosition.fromTicks(5000000, BookFamily.unknown), isNull);
    });

    test('a page past the end of a shorter file lands on the last one', () {
      expect(
        BookPosition.fromTicks(500 * 10000, BookFamily.pdf, pageCount: 20),
        const BookPosition.page(19, pageCount: 20),
      );
    });

    test('a fraction out of range is clamped rather than sent', () {
      expect(const BookPosition.fraction(1.4).ticks, 10000000);
      expect(const BookPosition.fraction(-0.2).ticks, 0);
    });

    test('progress and the end', () {
      expect(const BookPosition.fraction(0.42).progress, 0.42);
      expect(const BookPosition.page(0, pageCount: 4).progress, 0.25);
      expect(const BookPosition.page(3, pageCount: 4).progress, 1);
      expect(const BookPosition.page(3).progress, isNull);

      expect(const BookPosition.page(3, pageCount: 4).isFinished, isTrue);
      expect(const BookPosition.page(2, pageCount: 4).isFinished, isFalse);
      expect(const BookPosition.fraction(0.999).isFinished, isTrue);
      expect(const BookPosition.fraction(0.9).isFinished, isFalse);
    });
  });

  group('a format, from a file name', () {
    test('by extension, whatever its case', () {
      expect(BookFormat.fromPath('/books/Dune.EPUB'), BookFormat.epub);
      expect(BookFormat.fromPath(r'D:\books\a.b\Paper.pdf'), BookFormat.pdf);
      expect(BookFormat.fromPath('one.cbz'), BookFormat.cbz);
      expect(BookFormat.fromPath('one.azw'), BookFormat.azw3);
      expect(BookFormat.fromPath('one.txt'), BookFormat.unknown);
      expect(BookFormat.fromPath('noextension'), BookFormat.unknown);
      expect(BookFormat.fromPath(null), BookFormat.unknown);
    });

    test('families decide the reader and the position', () {
      expect(BookFormat.epub.family, BookFamily.reflowable);
      expect(BookFormat.mobi.family, BookFamily.reflowable);
      expect(BookFormat.pdf.family, BookFamily.pdf);
      expect(BookFormat.cbr.family, BookFamily.comic);
      expect(BookFormat.cbz.isReadableComic, isTrue);
      expect(BookFormat.cbr.isReadableComic, isFalse);
    });

    test('the first bytes name a PDF and the archives Dart cannot open', () {
      expect(BookFormat.sniff(utf8.encode('%PDF-1.7')), BookFormat.pdf);
      expect(BookFormat.sniff(utf8.encode('Rar!\x1a\x07')), BookFormat.cbr);
      expect(BookFormat.sniff(<int>[0x37, 0x7A, 0xBC, 0xAF]), BookFormat.cb7);
      // A zip is an EPUB or a comic; only the name knows which.
      expect(BookFormat.sniff(<int>[0x50, 0x4B, 3, 4]), isNull);
      expect(BookFormat.sniff(<int>[]), isNull);
    });
  });

  group('a book, as the server sends it', () {
    final book = serverItemFromJson(<String, dynamic>{
      'Id': 'b1',
      'Name': 'Dune Messiah',
      'Type': 'Book',
      'MediaType': 'Book',
      'ParentId': 'folder1',
      'Path': '/media/books/Herbert/Dune 2 - Dune Messiah.epub',
      'SeriesName': 'Dune',
      'IndexNumber': 2,
      'ProductionYear': 1969,
      'People': <dynamic>[
        <String, dynamic>{'Name': 'Frank Herbert', 'Type': 'Author'},
        <String, dynamic>{'Name': 'Someone Else', 'Type': 'Editor'},
      ],
      'UserData': <String, dynamic>{
        'PlaybackPositionTicks': 4200000,
        'Played': false,
      },
    });

    test('is a book, with its author, series and volume', () {
      expect(book.kind, ServerItemKind.book);
      expect(book.kind.isBook, isTrue);
      expect(book.authors, <String>['Frank Herbert']);
      expect(book.authorLine, 'Frank Herbert');
      expect(book.seriesTitle, 'Dune');
      expect(book.volumeNumber, 2);
      expect(book.parentId, 'folder1');
      expect(book.runtime, isNull);
    });

    test('keeps its position to the tick, and reads it by its format', () {
      expect(book.positionTicks, 4200000);
      expect(book.bookFormat, BookFormat.epub);
      expect(book.bookPosition, const BookPosition.fraction(0.42));
    });

    test('an audiobook credits whoever its tags do', () {
      final heard = serverItemFromJson(<String, dynamic>{
        'Id': 'a1',
        'Name': 'Dune',
        'Type': 'AudioBook',
        'MediaType': 'Audio',
        'AlbumArtist': 'Frank Herbert',
        'RunTimeTicks': 756000000000,
      });

      expect(heard.kind, ServerItemKind.audioBook);
      expect(heard.kind.isBook, isTrue);
      expect(heard.authors, <String>['Frank Herbert']);
      expect(heard.runtime, const Duration(hours: 21));
    });

    test('a book never opened has no position', () {
      final unread = serverItemFromJson(<String, dynamic>{
        'Id': 'b2',
        'Name': 'Unread',
        'Type': 'Book',
        'Path': '/x/unread.pdf',
        'UserData': <String, dynamic>{'PlaybackPositionTicks': 0},
      });

      expect(unread.positionTicks, isNull);
      expect(unread.bookPosition, isNull);
    });
  });

  group('what is asked of the server', () {
    test('a library grid asks for books beside films', () async {
      final (source, adapter) = _source(
        (_) => _json(<String, dynamic>{'Items': <dynamic>[]}),
      );

      await source.items('v1');
      await source.itemCount('v1');

      for (final RequestOptions request in adapter.requests) {
        final types = request.uri.queryParameters['includeItemTypes']!;
        expect(types, contains('Book'));
        expect(types, contains('AudioBook'));
        expect(types, contains('Movie'));
      }
    });

    test('the reading shelf asks for books, not songs or films', () async {
      final (source, adapter) = _source(
        (_) => _json(<String, dynamic>{'Items': <dynamic>[]}),
      );

      await source.resumableBooks(viewId: 'v1', limit: 5);

      final request = adapter.requests.single;
      expect(request.uri.path, '/UserItems/Resume');
      final query = request.uri.queryParameters;
      expect(query['mediaTypes'], 'Book,Audio');
      expect(query['includeItemTypes'], 'Book,AudioBook');
      expect(query['parentId'], 'v1');
      expect(query['limit'], '5');
    });

    test(
      'a position is written as user data, never as a play report',
      () async {
        final (source, adapter) = _source((_) => _json(<String, dynamic>{}));

        await source.setBookPosition('b1', const BookPosition.fraction(0.5));

        final request = adapter.requests.single;
        // The route matters more than anything else in this file: a progress
        // report on an item with no runtime marks it read and zeroes it.
        expect(request.method, 'POST');
        expect(request.uri.path, '/UserItems/b1/UserData');
        expect(request.uri.path, isNot(contains('Sessions')));
        expect(request.uri.queryParameters['userId'], 'u1');

        final body = request.data as Map<String, dynamic>;
        expect(body['PlaybackPositionTicks'], 5000000);
        // Left alone unless said: reading on must not un-read a finished book,
        // nor finish one.
        expect(body.containsKey('Played'), isFalse);
        expect(DateTime.tryParse(body['LastPlayedDate'] as String), isNotNull);
      },
    );

    test('finishing marks it read and starts it over', () async {
      final (source, adapter) = _source((_) => _json(<String, dynamic>{}));

      await source.setBookPosition(
        'b1',
        const BookPosition.page(299, pageCount: 300),
        finished: true,
      );

      final body = adapter.requests.single.data as Map<String, dynamic>;
      expect(body['Played'], isTrue);
      expect(body['PlaybackPositionTicks'], 0);
    });

    test('a series is the folder, narrowed to the name', () async {
      final (source, adapter) = _source(
        (_) => _json(<String, dynamic>{
          'Items': <dynamic>[
            <String, dynamic>{
              'Id': 'b1',
              'Name': 'Dune',
              'Type': 'Book',
              'SeriesName': 'Dune',
            },
            <String, dynamic>{
              'Id': 'b9',
              'Name': 'The Dosadi Experiment',
              'Type': 'Book',
              'SeriesName': 'ConSentiency',
            },
            <String, dynamic>{'Id': 'b3', 'Name': 'Loose', 'Type': 'Book'},
          ],
        }),
      );

      final volumes = await source.bookSeries('folder1', 'Dune');

      expect(volumes.map((b) => b.id), <String>['b1']);
      final query = adapter.requests.single.uri.queryParameters;
      expect(query['parentId'], 'folder1');
      expect(query['sortBy'], startsWith('IndexNumber'));
    });

    test('search can ask for books', () async {
      final (source, adapter) = _source(
        (_) => _json(<String, dynamic>{'Items': <dynamic>[]}),
      );

      await source.search(
        'dune',
        kinds: const <ServerItemKind>{
          ServerItemKind.book,
          ServerItemKind.audioBook,
        },
      );

      expect(
        adapter.requests.single.uri.queryParameters['includeItemTypes'],
        'Book,AudioBook',
      );
    });
  });
}

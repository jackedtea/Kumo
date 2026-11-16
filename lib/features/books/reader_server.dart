// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Serves the EPUB reader's page and one book to the WebView, on loopback.
///
/// Not `file://`: Chromium refuses ES modules from it, and foliate-js is
/// nothing but modules. Not a custom scheme either — each platform's WebView
/// wires those differently, and this has to behave the same on four. A
/// socket bound to 127.0.0.1 is the one thing all of them load alike.
///
/// Every path starts with a random token, so another app on the device that
/// finds the port still cannot read the book. One book per server; the
/// reader starts one when it opens and closes it when it goes.
class ReaderServer {
  ReaderServer._(this._server, this._token, this._book);

  final HttpServer _server;
  final String _token;
  final File _book;

  static const _assets = 'assets/foliate';

  /// Starts a server for [book].
  static Future<ReaderServer> start(File book) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List<String>.generate(
      24,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
    final reader = ReaderServer._(server, token, book);
    server.listen(
      reader._handle,
      onError: (Object e) {
        debugPrint('Reader server: $e');
      },
    );
    return reader;
  }

  Uri get _root => Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: _server.port,
    path: '/$_token/',
  );

  /// The book, named with its extension: foliate tells a CBZ from an EPUB,
  /// and an FB2 from a MOBI, by the name.
  Uri get bookUri => _root.resolve('book${p.extension(_book.path)}');

  /// The reader page, told which book to open and how.
  Uri pageUri(Map<String, String> query) => _root
      .resolve('kumo.html')
      .replace(
        queryParameters: <String, String>{'book': bookUri.toString(), ...query},
      );

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (request.method != 'GET' ||
          segments.length < 2 ||
          segments.first != _token) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final rest = segments.skip(1).join('/');
      // Nothing in the page is worth caching across books, and a stale
      // kumo.js after an update would be a reader that does not answer.
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

      if (rest.startsWith('book')) {
        response.headers.contentType = ContentType.binary;
        response.contentLength = await _book.length();
        await response.addStream(_book.openRead());
        return;
      }

      // Only the bundled files, by name: no `..` reaches the asset bundle,
      // and nothing else on disk is ever served.
      if (rest.contains('..') || !_servable.hasMatch(rest)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final ByteData data;
      try {
        data = await rootBundle.load('$_assets/$rest');
      } on Object {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      response.headers.contentType = _typeOf(rest);
      response.add(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } on Object catch (e) {
      debugPrint('Reader server request failed: $e');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close();
    }
  }

  static final _servable = RegExp(r'^[a-z0-9_./-]+\.(html|js)$');

  static ContentType _typeOf(String name) => name.endsWith('.html')
      ? ContentType.html
      : ContentType('text', 'javascript', charset: 'utf-8');
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../downloads/download_models.dart';
import '../../downloads/downloads_controller.dart';
import '../../servers/books.dart';
import '../../servers/media_library_source.dart';

/// Why a book could not be had.
enum BookFileFailure {
  /// The server refused: this account may not download, and reading a book
  /// is downloading it — the web reader is refused the same way.
  forbidden,

  /// The server could not be reached, or the transfer broke off.
  unreachable,

  /// Anything else: a full disk, a server error.
  other,
}

class BookFileException implements Exception {
  const BookFileException(this.failure, [this.detail]);

  final BookFileFailure failure;

  /// For the log, never the screen.
  final String? detail;

  @override
  String toString() => 'BookFileException($failure, $detail)';
}

/// A finished book in the cache, as eviction sees it.
@immutable
class CachedBook {
  const CachedBook({
    required this.path,
    required this.bytes,
    required this.lastUsed,
  });

  final String path;
  final int bytes;
  final DateTime lastUsed;
}

/// Which cached books to delete so the rest fit in [budget] bytes: the
/// least recently opened first, and never [keep] — the book about to be
/// read, which may on its own be larger than the budget.
List<CachedBook> booksToEvict(
  List<CachedBook> books, {
  required int budget,
  String? keep,
}) {
  var total = books.fold<int>(0, (sum, b) => sum + b.bytes);
  if (total <= budget) return const <CachedBook>[];

  final oldestFirst = <CachedBook>[...books]
    ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
  final evicted = <CachedBook>[];
  for (final CachedBook book in oldestFirst) {
    if (total <= budget) break;
    if (book.path == keep) continue;
    evicted.add(book);
    total -= book.bytes;
  }
  return evicted;
}

/// The file name a server gave in `Content-Disposition`, or null.
@visibleForTesting
String? dispositionFileName(String? header) {
  if (header == null) return null;
  // RFC 5987 first: `filename*=UTF-8''Dune%20Messiah.epub`.
  final star = RegExp(
    r"filename\*\s*=\s*[^']*'[^']*'([^;]+)",
    caseSensitive: false,
  ).firstMatch(header);
  if (star != null) {
    try {
      return Uri.decodeComponent(star.group(1)!.trim());
    } on ArgumentError {
      // Fall through to the plain form.
    }
  }
  final plain = RegExp(
    r'filename\s*=\s*"?([^";]+)"?',
    caseSensitive: false,
  ).firstMatch(header);
  return plain?.group(1)?.trim();
}

/// Book files on this device, for the reader.
///
/// A reader needs the whole file — an EPUB or a CBZ is a zip, whose
/// directory is at its end — so a book is always read from disk: the
/// downloaded copy when there is one, otherwise a copy fetched into the
/// cache. Not through the downloads engine: that queue runs one file at a
/// time, and a novel opened while a film downloads must not wait behind it.
///
/// Like a download, the URL carries the token and is rebuilt every time;
/// nothing on disk holds it.
class BookFiles {
  BookFiles({
    required this.root,
    Dio? client,
    this.budgetBytes = 1024 * 1024 * 1024,
  }) : _dio = client ?? Dio();

  /// `<cache>/books`.
  final Directory root;

  /// How much the cache may hold before the least recently read go.
  final int budgetBytes;

  final Dio _dio;

  static const _stem = 'book';
  static const _partName = 'book.part';

  Directory _dirFor(String profileId, String itemId) =>
      Directory(p.join(root.path, _safe(profileId), _safe(itemId)));

  /// The cached copy of [itemId], or null before there is a whole one.
  File? cached(String profileId, String itemId) {
    final dir = _dirFor(profileId, itemId);
    if (!dir.existsSync()) return null;
    for (final FileSystemEntity e in dir.listSync()) {
      final name = p.basename(e.path);
      if (e is File && name.startsWith('$_stem.') && name != _partName) {
        return e;
      }
    }
    return null;
  }

  /// The book [item] on disk, fetched from [source] if it is not already.
  ///
  /// [onProgress] hears the bytes as they arrive; the total is null where
  /// the server did not say. Throws [BookFileException].
  Future<File> fetch(
    MediaLibrarySource source,
    ServerItem item, {
    void Function(int received, int? total)? onProgress,
    CancelToken? cancel,
  }) async {
    final profileId = source.profile.id;
    final existing = cached(profileId, item.id);
    if (existing != null) {
      _touch(existing);
      return existing;
    }

    final dir = _dirFor(profileId, item.id);
    final part = File(p.join(dir.path, _partName));
    String? named;
    try {
      await dir.create(recursive: true);
      var offset = await part.exists() ? await part.length() : 0;

      final Response<ResponseBody> response;
      try {
        response = await _dio.getUri<ResponseBody>(
          source.downloadUrl(item.id),
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            validateStatus: (_) => true,
            headers: <String, String>{
              if (offset > 0) 'Range': 'bytes=$offset-',
            },
          ),
        );
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
        throw BookFileException(BookFileFailure.unreachable, e.type.name);
      }

      final status = response.statusCode ?? 0;
      final body = response.data;
      named = dispositionFileName(
        response.headers.value('content-disposition'),
      );

      if (status == 401 || status == 403) {
        throw BookFileException(BookFileFailure.forbidden, '$status');
      }
      // A range past the end: the part file already holds all of it.
      final complete = status == 416 && offset > 0;
      if (!complete && status != 200 && status != 206) {
        throw BookFileException(BookFileFailure.other, '$status');
      }

      if (!complete && body != null) {
        // A 200 to a range request is the whole file again: start over.
        if (status == 200) offset = 0;
        final length = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        );
        final total = length == null ? null : offset + length;
        final sink = part.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        var received = offset;
        try {
          await for (final Uint8List chunk in body.stream) {
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received, total);
          }
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) rethrow;
          throw BookFileException(BookFileFailure.unreachable, e.type.name);
        } finally {
          await sink.close();
        }
        if (total != null && received < total) {
          throw const BookFileException(
            BookFileFailure.unreachable,
            'short read',
          );
        }
      }

      final file = File(
        p.join(dir.path, '$_stem.${await _extensionFor(item, named, part)}'),
      );
      await part.rename(file.path);
      _touch(file);
      unawaited(_evict(keep: file.path));
      return file;
    } on BookFileException {
      rethrow;
    } on DioException {
      rethrow;
    } on FileSystemException catch (e) {
      throw BookFileException(BookFileFailure.other, e.message);
    }
  }

  /// Every cached book, for the space line in the settings.
  Future<int> sizeBytes() async =>
      (await _all()).fold<int>(0, (sum, b) => sum + b.bytes);

  /// Empties the cache. Downloaded copies are not in it.
  Future<void> clear() async {
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('Could not clear the book cache: ${e.message}');
    }
  }

  Future<String> _extensionFor(
    ServerItem item,
    String? named,
    File part,
  ) async {
    final fromItem = item.bookFormat;
    if (fromItem != BookFormat.unknown) return fromItem.extension;
    final fromName = BookFormat.fromPath(named);
    if (fromName != BookFormat.unknown) return fromName.extension;
    try {
      final raf = await part.open();
      final head = await raf.read(8);
      await raf.close();
      final sniffed = BookFormat.sniff(head);
      if (sniffed != null) return sniffed.extension;
    } on FileSystemException {
      // Unknown it stays.
    }
    // A zip with no name to say otherwise is far more often an EPUB.
    return BookFormat.epub.extension;
  }

  void _touch(File file) {
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // The order of eviction is a nicety.
    }
  }

  Future<List<CachedBook>> _all() async {
    final books = <CachedBook>[];
    if (!await root.exists()) return books;
    await for (final FileSystemEntity e in root.list(recursive: true)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (!name.startsWith('$_stem.') || name == _partName) continue;
      try {
        final stat = await e.stat();
        books.add(
          CachedBook(path: e.path, bytes: stat.size, lastUsed: stat.modified),
        );
      } on FileSystemException {
        continue;
      }
    }
    return books;
  }

  Future<void> _evict({String? keep}) async {
    try {
      final books = await _all();
      for (final CachedBook b in booksToEvict(
        books,
        budget: budgetBytes,
        keep: keep,
      )) {
        await Directory(p.dirname(b.path)).delete(recursive: true);
      }
    } on FileSystemException catch (e) {
      // A book open in another window on Windows; next time.
      debugPrint('Could not trim the book cache: ${e.message}');
    }
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}

final bookFilesProvider = FutureProvider<BookFiles>((ref) async {
  final base = await getApplicationCacheDirectory();
  return BookFiles(root: Directory(p.join(base.path, 'books')));
});

/// The downloaded copy of [itemId] for [profileId], whole, or null.
File? downloadedBook(WidgetRef ref, String profileId, String itemId) {
  final store = ref.read(downloadsProvider.notifier).store;
  if (store == null) return null;
  final key = DownloadEntry.keyOf(profileId, itemId);
  for (final DownloadEntry e in ref.read(downloadsProvider)) {
    if (e.key != key || e.status != DownloadStatus.completed) continue;
    final file = store.mediaFile(e);
    if (file != null && file.existsSync()) return file;
  }
  return null;
}

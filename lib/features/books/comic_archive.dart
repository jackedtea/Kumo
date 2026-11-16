// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../servers/books.dart';

/// Compares names the way a person numbers pages: "2.jpg" before "10.jpg".
///
/// A comic's pages are its file names in order, and a plain string sort
/// puts page 10 straight after page 1 in every archive whose scanner did
/// not pad the numbers.
int naturalCompare(String a, String b) {
  final x = a.toLowerCase();
  final y = b.toLowerCase();
  var i = 0;
  var j = 0;
  bool isDigit(int c) => c >= 0x30 && c <= 0x39;
  while (i < x.length && j < y.length) {
    final cx = x.codeUnitAt(i);
    final cy = y.codeUnitAt(j);
    if (isDigit(cx) && isDigit(cy)) {
      final si = i;
      final sj = j;
      while (i < x.length && isDigit(x.codeUnitAt(i))) {
        i++;
      }
      while (j < y.length && isDigit(y.codeUnitAt(j))) {
        j++;
      }
      final nx = BigInt.parse(x.substring(si, i));
      final ny = BigInt.parse(y.substring(sj, j));
      final c = nx.compareTo(ny);
      if (c != 0) return c;
      // "01" and "1": the shorter first, so the order is still total.
      final l = (i - si).compareTo(j - sj);
      if (l != 0) return l;
      continue;
    }
    if (cx != cy) return cx.compareTo(cy);
    i++;
    j++;
  }
  return (x.length - i).compareTo(y.length - j);
}

const _imageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.avif',
};

/// Whether an archive entry is a page: an image, and not the clutter a
/// Mac or a scanner leaves in a zip.
bool isComicPage(String name) {
  final lower = name.toLowerCase();
  final base = p.posix.basename(lower);
  if (lower.startsWith('__macosx/') || base.startsWith('.')) return false;
  return _imageExtensions.contains(p.posix.extension(lower));
}

/// Which pages a spread shows, starting from the spread at [index]: the
/// cover alone, then pairs.
List<int> spreadPages(int index, int pageCount) {
  if (index <= 0) return const <int>[0];
  final first = index * 2 - 1;
  return <int>[first, if (first + 1 < pageCount) first + 1];
}

/// The spread holding [page].
int spreadOf(int page) => page <= 0 ? 0 : (page + 1) ~/ 2;

/// How many spreads [pageCount] pages make.
int spreadCount(int pageCount) =>
    pageCount <= 0 ? 0 : spreadOf(pageCount - 1) + 1;

/// A CBZ or CBT, opened for its pages.
///
/// Reads the directory once and each page when it is asked for — never the
/// whole archive into memory, which for a 300 MB omnibus is the difference
/// between a reader and a crash.
class ComicArchive {
  ComicArchive._(this._input, this._pages);

  final InputFileStream _input;
  final List<ArchiveFile> _pages;

  /// Opens [path] as [format]. Throws on anything that is not a readable
  /// zip or tar.
  static ComicArchive open(String path, BookFormat format) {
    final input = InputFileStream(path);
    try {
      final archive = format == BookFormat.cbt
          ? TarDecoder().decodeStream(input)
          : ZipDecoder().decodeStream(input);
      final pages =
          archive.files.where((f) => f.isFile && isComicPage(f.name)).toList()
            ..sort((a, b) => naturalCompare(a.name, b.name));
      return ComicArchive._(input, pages);
    } on Object {
      input.closeSync();
      rethrow;
    }
  }

  int get pageCount => _pages.length;

  /// The bytes of page [index], or null for one that will not read.
  Uint8List? page(int index) {
    if (index < 0 || index >= _pages.length) return null;
    try {
      return _pages[index].readBytes();
    } on Object {
      return null;
    }
  }

  void close() => _input.closeSync();
}

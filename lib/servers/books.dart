// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

/// What a book file is, and where in it the reader stopped.
///
/// Pure, like `jellyfin_dto.dart`: nothing here touches the network or a
/// widget, so the tick encoding — the one thing that has to agree with
/// jellyfin-web to the digit — is tested with no server.
library;

import 'package:flutter/foundation.dart';

/// How a book is drawn, which is also how its position is counted.
enum BookFamily {
  /// Text that flows to fit the screen: EPUB and its relatives. A position
  /// is a fraction of the whole book, because a "page" depends on the font.
  reflowable,

  /// Fixed pages: a PDF.
  pdf,

  /// An archive of page images.
  comic,

  /// Nothing this app can open.
  unknown,
}

/// A book file's format, from its extension.
enum BookFormat {
  epub('epub', BookFamily.reflowable),
  mobi('mobi', BookFamily.reflowable),
  azw3('azw3', BookFamily.reflowable),
  fb2('fb2', BookFamily.reflowable),
  pdf('pdf', BookFamily.pdf),
  cbz('cbz', BookFamily.comic),
  cbt('cbt', BookFamily.comic),

  /// RAR and 7-Zip comics. Listed so the screen can name what it will not
  /// open; there is no decoder for either in Dart.
  cbr('cbr', BookFamily.comic),
  cb7('cb7', BookFamily.comic),
  unknown('', BookFamily.unknown);

  const BookFormat(this.extension, this.family);

  /// Lower case, no dot.
  final String extension;
  final BookFamily family;

  /// "EPUB", for a badge. Empty for [unknown].
  String get label => extension.toUpperCase();

  /// Whether the archive can be read without a native decoder.
  bool get isReadableComic => this == cbz || this == cbt;

  /// The format a path or a file name ends in. `azw` is read as [azw3]: the
  /// engine that opens one opens the other.
  static BookFormat fromPath(String? path) {
    if (path == null) return unknown;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return unknown;
    final ext = path.substring(dot + 1).toLowerCase();
    if (ext == 'azw' || ext == 'kf8') return azw3;
    for (final BookFormat format in values) {
      if (format != unknown && format.extension == ext) return format;
    }
    return unknown;
  }

  /// The format the first bytes of a file say it is, for a file the server
  /// named nothing useful for. Null when they say nothing: a zip is an EPUB
  /// or a comic and only the name tells them apart.
  static BookFormat? sniff(List<int> head) {
    bool starts(List<int> magic) {
      if (head.length < magic.length) return false;
      for (var i = 0; i < magic.length; i++) {
        if (head[i] != magic[i]) return false;
      }
      return true;
    }

    // "%PDF"
    if (starts(const <int>[0x25, 0x50, 0x44, 0x46])) return pdf;
    // "Rar!"
    if (starts(const <int>[0x52, 0x61, 0x72, 0x21])) return cbr;
    // "7z\xBC\xAF"
    if (starts(const <int>[0x37, 0x7A, 0xBC, 0xAF])) return cb7;
    return null;
  }
}

/// Jellyfin's unit: 100 ns. Ten million to the second.
const _ticksPerSecond = 10000000;
const _ticksPerMillisecond = 10000;

/// Where the reader is in a book.
///
/// Stored on the server as `PlaybackPositionTicks`, in **jellyfin-web's
/// encoding**, so a book left in a browser opens at the same place here and
/// the other way round. The web client reports a "current time" in
/// milliseconds and the server multiplies by 10 000:
///
/// * an EPUB's time is `fraction × 1000`, so ticks = fraction × 10 000 000;
/// * a PDF's and a comic's is the zero-based page, so ticks = page × 10 000.
///
/// Zero is "not started" on the server, which is the one loss: the first
/// page of a PDF cannot be told from a book never opened. Nobody resumes at
/// the first page.
@immutable
class BookPosition {
  /// A place in a reflowable book, 0..1.
  const BookPosition.fraction(double this.fraction)
    : pageIndex = null,
      pageCount = null;

  /// A page of a paged book, counted from zero. [pageCount] is what makes a
  /// percentage of it; the server keeps only the index.
  const BookPosition.page(int this.pageIndex, {this.pageCount})
    : fraction = null;

  final double? fraction;
  final int? pageIndex;
  final int? pageCount;

  /// What the server stores.
  int get ticks {
    final page = pageIndex;
    if (page != null) return page < 0 ? 0 : page * _ticksPerMillisecond;
    final at = (fraction ?? 0).clamp(0.0, 1.0);
    return (at * _ticksPerSecond).round();
  }

  /// 0..1 through the book, or null for a page with no total to divide by.
  double? get progress {
    final at = fraction;
    if (at != null) return at.clamp(0.0, 1.0);
    final count = pageCount;
    final page = pageIndex;
    if (page == null || count == null || count <= 0) return null;
    // The last page is the whole book, not one page short of it.
    return ((page + 1) / count).clamp(0.0, 1.0);
  }

  /// Whether this is the end: the last page, or as good as the last line.
  bool get isFinished {
    final at = fraction;
    if (at != null) return at >= 0.995;
    final count = pageCount;
    final page = pageIndex;
    return page != null && count != null && count > 0 && page >= count - 1;
  }

  /// Reads [ticks] back for a book of [family]. Null for nothing stored, and
  /// for a family that has no position.
  static BookPosition? fromTicks(
    int? ticks,
    BookFamily family, {
    int? pageCount,
  }) {
    if (ticks == null || ticks <= 0) return null;
    switch (family) {
      case BookFamily.reflowable:
        return BookPosition.fraction((ticks / _ticksPerSecond).clamp(0.0, 1.0));
      case BookFamily.pdf:
      case BookFamily.comic:
        var page = ticks ~/ _ticksPerMillisecond;
        // A file replaced by a shorter one: the old page no longer exists.
        if (pageCount != null && pageCount > 0 && page >= pageCount) {
          page = pageCount - 1;
        }
        return BookPosition.page(page, pageCount: pageCount);
      case BookFamily.unknown:
        return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BookPosition &&
      other.fraction == fraction &&
      other.pageIndex == pageIndex &&
      other.pageCount == pageCount;

  @override
  int get hashCode => Object.hash(fraction, pageIndex, pageCount);

  @override
  String toString() => fraction != null
      ? 'BookPosition(${(fraction! * 100).toStringAsFixed(1)} %)'
      : 'BookPosition(page $pageIndex of $pageCount)';
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../servers/books.dart';
import 'reader_settings.dart';

/// One entry of a book's table of contents.
@immutable
class ReaderTocEntry {
  const ReaderTocEntry({
    required this.label,
    this.depth = 0,
    this.href,
    this.fraction,
    this.page,
  });

  final String label;
  final int depth;

  /// Where it points, in whichever terms the engine understands.
  final String? href;
  final double? fraction;
  final int? page;
}

/// Where the reader is, as the chrome draws it.
@immutable
class ReaderLocation {
  const ReaderLocation({required this.position, this.chapter});

  final BookPosition position;

  /// The chapter title, where the book names one.
  final String? chapter;
}

/// What the chrome can ask of whichever engine is drawing the book.
///
/// Three engines — a WebView for reflowable text, PDFium for PDFs, the
/// archive for comics — behind the one set of controls, so the reader's
/// top and bottom bars are written once.
abstract class ReaderEngine {
  Future<void> next();
  Future<void> previous();

  /// Jumps to [fraction] of the way through, 0..1.
  Future<void> goToFraction(double fraction);

  Future<void> goToEntry(ReaderTocEntry entry);

  List<ReaderTocEntry> get contents;

  /// The pages of a paged book, for the slider's steps. Null for text.
  int? get pageCount;
}

/// What an engine widget is handed.
@immutable
class ReaderEngineArgs {
  const ReaderEngineArgs({
    required this.file,
    required this.format,
    required this.settings,
    required this.background,
    required this.start,
    required this.onReady,
    required this.onLocation,
    required this.onTap,
    required this.onFailed,
  });

  final File file;
  final BookFormat format;
  final ReaderSettings settings;

  /// The page colour, which every engine paints under its content.
  final Color background;

  /// Where to open, or null for the beginning.
  final BookPosition? start;

  final ValueChanged<ReaderEngine> onReady;
  final ValueChanged<ReaderLocation> onLocation;

  /// A tap in the middle of the page: show or hide the chrome.
  final VoidCallback onTap;

  /// The engine could not open the file. The detail is for the log.
  final ValueChanged<String> onFailed;
}

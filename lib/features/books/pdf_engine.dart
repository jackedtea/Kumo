// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../servers/books.dart';
import 'reader_engine.dart';

/// A PDF, drawn by PDFium.
///
/// Pages run top to bottom and zoom with a pinch, as every PDF viewer does;
/// "turning a page" is a jump to the next one.
class PdfEngineView extends StatefulWidget {
  const PdfEngineView({super.key, required this.args});

  final ReaderEngineArgs args;

  @override
  State<PdfEngineView> createState() => _PdfEngineViewState();
}

class _PdfEngineViewState extends State<PdfEngineView> implements ReaderEngine {
  final _controller = PdfViewerController();
  List<ReaderTocEntry> _contents = const <ReaderTocEntry>[];
  int _pages = 0;
  int _page = 1;

  @override
  Future<void> next() => _goTo(_page + 1);

  @override
  Future<void> previous() => _goTo(_page - 1);

  @override
  Future<void> goToFraction(double fraction) {
    if (_pages <= 0) return Future<void>.value();
    return _goTo((fraction.clamp(0.0, 1.0) * (_pages - 1)).round() + 1);
  }

  @override
  Future<void> goToEntry(ReaderTocEntry entry) {
    final page = entry.page;
    return page == null ? Future<void>.value() : _goTo(page + 1);
  }

  Future<void> _goTo(int pageNumber) async {
    if (!_controller.isReady || _pages <= 0) return;
    await _controller.goToPage(pageNumber: pageNumber.clamp(1, _pages));
  }

  @override
  List<ReaderTocEntry> get contents => _contents;

  @override
  int? get pageCount => _pages;

  Future<void> _ready(PdfDocument document) async {
    _pages = document.pages.length;
    try {
      final outline = await document.loadOutline();
      final flat = <ReaderTocEntry>[];
      void walk(List<PdfOutlineNode> nodes, int depth) {
        for (final PdfOutlineNode n in nodes) {
          final page = n.dest?.pageNumber;
          if (n.title.trim().isNotEmpty) {
            flat.add(
              ReaderTocEntry(
                label: n.title.trim(),
                depth: depth,
                page: page == null ? null : page - 1,
              ),
            );
          }
          walk(n.children, depth + 1);
        }
      }

      walk(outline, 0);
      _contents = flat;
    } on Object {
      // A PDF with no outline is the common case.
    }
    if (!mounted) return;
    widget.args.onReady(this);
    _report(_page);
  }

  void _report(int pageNumber) {
    _page = pageNumber;
    widget.args.onLocation(
      ReaderLocation(
        position: BookPosition.page(pageNumber - 1, pageCount: _pages),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.args.start?.pageIndex;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.args.onTap,
      child: PdfViewer.file(
        widget.args.file.path,
        controller: _controller,
        initialPageNumber: start == null ? 1 : start + 1,
        params: PdfViewerParams(
          backgroundColor: widget.args.background,
          margin: 8,
          onViewerReady: (document, controller) => unawaited(_ready(document)),
          onPageChanged: (pageNumber) {
            if (pageNumber != null) _report(pageNumber);
          },
          errorBannerBuilder: (context, error, stackTrace, documentRef) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => widget.args.onFailed('$error'),
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../servers/books.dart';
import 'comic_archive.dart';
import 'reader_engine.dart';

/// A CBZ or CBT, a page (or a spread) at a time.
class ComicEngineView extends StatefulWidget {
  const ComicEngineView({super.key, required this.args});

  final ReaderEngineArgs args;

  @override
  State<ComicEngineView> createState() => _ComicEngineViewState();
}

class _ComicEngineViewState extends State<ComicEngineView>
    implements ReaderEngine {
  ComicArchive? _archive;
  PageController? _pager;

  /// The first page on screen.
  int _page = 0;

  /// Decoded bytes for the pages near the one on screen. Two either side:
  /// enough that a swipe never waits, few enough that a phone holds them.
  final _bytes = <int, Uint8List?>{};

  bool _spread = false;

  @override
  void initState() {
    super.initState();
    try {
      final archive = ComicArchive.open(
        widget.args.file.path,
        widget.args.format,
      );
      if (archive.pageCount == 0) {
        archive.close();
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.args.onFailed('no pages'),
        );
        return;
      }
      _archive = archive;
      _page = (widget.args.start?.pageIndex ?? 0).clamp(
        0,
        archive.pageCount - 1,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.args.onReady(this);
        _report();
      });
    } on Object catch (e) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.args.onFailed('$e'),
      );
    }
  }

  @override
  void dispose() {
    _pager?.dispose();
    _archive?.close();
    super.dispose();
  }

  int get _count => _archive?.pageCount ?? 0;

  int _indexOfPage(int page) => _spread ? spreadOf(page) : page;

  int get _indexCount => _spread ? spreadCount(_count) : _count;

  List<int> _pagesAt(int index) =>
      _spread ? spreadPages(index, _count) : <int>[index];

  Uint8List? _load(int page) {
    if (_bytes.containsKey(page)) return _bytes[page];
    final bytes = _archive?.page(page);
    _bytes[page] = bytes;
    _bytes.removeWhere((k, _) => (k - page).abs() > 3 && (k - _page).abs() > 3);
    return bytes;
  }

  void _report() {
    widget.args.onLocation(
      ReaderLocation(position: BookPosition.page(_page, pageCount: _count)),
    );
  }

  Future<void> _show(int page) async {
    final pager = _pager;
    if (pager == null || !pager.hasClients) return;
    final target = _indexOfPage(page.clamp(0, math.max(0, _count - 1)));
    await pager.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Future<void> next() =>
      _show(_spread ? _pagesAt(_indexOfPage(_page)).last + 1 : _page + 1);

  @override
  Future<void> previous() => _show(
    _spread ? _pagesAt(math.max(0, _indexOfPage(_page) - 1)).first : _page - 1,
  );

  @override
  Future<void> goToFraction(double fraction) =>
      _show((fraction.clamp(0.0, 1.0) * math.max(0, _count - 1)).round());

  @override
  Future<void> goToEntry(ReaderTocEntry entry) =>
      entry.page == null ? Future<void>.value() : _show(entry.page!);

  @override
  List<ReaderTocEntry> get contents => const <ReaderTocEntry>[];

  @override
  int? get pageCount => _count;

  /// A tap: the outer thirds turn the page, the middle shows the chrome.
  /// In manga order the left third goes forward.
  void _onTap(TapUpDetails details, double width) {
    final at = details.localPosition.dx / width;
    final forward = widget.args.settings.comicRightToLeft
        ? at < 0.28
        : at > 0.72;
    final back = widget.args.settings.comicRightToLeft ? at > 0.72 : at < 0.28;
    if (forward) {
      next();
    } else if (back) {
      previous();
    } else {
      widget.args.onTap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final archive = _archive;
    if (archive == null) return ColoredBox(color: widget.args.background);

    return LayoutBuilder(
      builder: (context, constraints) {
        final settings = widget.args.settings;
        final spread =
            settings.comicSpread &&
            constraints.maxWidth > constraints.maxHeight &&
            constraints.maxWidth >= 840;
        if (spread != _spread || _pager == null) {
          _spread = spread;
          // Still attached to the PageView this frame replaces; let go of
          // it once that one is gone.
          final old = _pager;
          if (old != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
          _pager = PageController(initialPage: _indexOfPage(_page));
        }
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final pageWidth = (constraints.maxWidth / (spread ? 2 : 1) * dpr)
            .round();

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTap(d, constraints.maxWidth),
          child: ColoredBox(
            color: widget.args.background,
            child: PageView.builder(
              // A new view when the spread comes or goes: its pages are
              // numbered differently, and the old scroll offset means nothing.
              key: ValueKey<bool>(spread),
              controller: _pager,
              reverse: settings.comicRightToLeft,
              itemCount: _indexCount,
              onPageChanged: (index) {
                _page = _pagesAt(index).first;
                _report();
              },
              itemBuilder: (context, index) {
                final pages = _pagesAt(index);
                final images = <Widget>[
                  for (final int page in pages)
                    Expanded(
                      child: _PageImage(bytes: _load(page), width: pageWidth),
                    ),
                ];
                return InteractiveViewer(
                  maxScale: 4,
                  child: Row(
                    textDirection: settings.comicRightToLeft
                        ? TextDirection.rtl
                        : TextDirection.ltr,
                    children: images,
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _PageImage extends StatelessWidget {
  const _PageImage({required this.bytes, required this.width});

  final Uint8List? bytes;

  /// Decoded at the screen's width, not the scan's: a 4000px page decoded
  /// whole is 60 MB of pixels, and a phone holds few of those.
  final int width;

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    if (data == null) {
      return Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Image.memory(
      data,
      fit: BoxFit.contain,
      cacheWidth: width,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) =>
          const Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
}

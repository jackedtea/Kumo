// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/system_ui.dart';
import '../../app/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../servers/books.dart';
import '../../servers/media_library_source.dart';
import '../player/playback_state.dart';
import '../servers/server_library.dart';
import 'book_files.dart';
import 'book_progress.dart';
import 'comic_engine.dart';
import 'epub_engine.dart';
import 'pdf_engine.dart';
import 'reader_engine.dart';
import 'reader_settings.dart';
import 'reader_sheets.dart';

/// Opens [item] in the reader.
///
/// [profileId] names the server a downloaded copy came from, for a book
/// opened from the Downloads tab — possibly with that server not signed in.
void openBookReader(
  BuildContext context,
  ServerItem item, {
  String? profileId,
}) {
  context.push(
    '/reader',
    extra: BookReaderLaunch(item: item, profileId: profileId),
  );
}

/// What the `/reader` route is pushed with.
@immutable
class BookReaderLaunch {
  const BookReaderLaunch({required this.item, this.profileId});

  final ServerItem item;
  final String? profileId;
}

/// Whether this platform can hand a file to another app by its path.
///
/// The desktops can. A phone needs a content URI through a file provider,
/// which nothing here sets up for books, so there the reader says it cannot
/// open the format instead of offering a button that would fail.
bool get canHandOffFiles =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Which engine reads [format] here, or null for none.
enum _Engine { web, pdf, comic }

_Engine? _engineFor(BookFormat format, {required bool webView}) =>
    switch (format.family) {
      BookFamily.reflowable => webView ? _Engine.web : null,
      BookFamily.pdf => _Engine.pdf,
      BookFamily.comic => format.isReadableComic ? _Engine.comic : null,
      BookFamily.unknown => null,
    };

/// The reader: one book, full screen, with chrome that a tap shows.
///
/// It fetches the file first (or finds it on disk), then hands it to the
/// engine its format needs. Where the position goes is decided here, once,
/// for all three engines: `BookProgressSaver` to the server.
class BookReaderPage extends ConsumerStatefulWidget {
  const BookReaderPage({super.key, required this.item, this.profileId});

  /// As the detail screen had it, which carries the format (from `Path`)
  /// and the server's position.
  final ServerItem? item;

  /// The server the book belongs to, when it is not the one signed in.
  final String? profileId;

  @override
  ConsumerState<BookReaderPage> createState() => _BookReaderPageState();
}

sealed class _Stage {
  const _Stage();
}

class _Fetching extends _Stage {
  const _Fetching([this.fraction]);
  final double? fraction;
}

class _Failed extends _Stage {
  const _Failed(this.message, {this.file});
  final String message;

  /// A file to hand to another app instead, where there is one.
  final File? file;
}

class _Reading extends _Stage {
  const _Reading(this.file, this.format, this.engine);
  final File file;
  final BookFormat format;
  final _Engine engine;
}

class _BookReaderPageState extends ConsumerState<BookReaderPage> {
  _Stage _stage = const _Fetching();
  final _cancel = CancelToken();
  final _focus = FocusNode(debugLabel: 'reader');

  ReaderEngine? _engine;
  ReaderLocation? _location;
  BookPosition? _start;
  BookProgressSaver? _saver;
  bool _chrome = true;
  Timer? _hideChrome;
  WindowEdgesClaim? _edges;

  /// Read up front: `ref` is gone by the time `dispose` wants it.
  late final PlaybackStops _stops;

  @override
  void initState() {
    super.initState();
    _stops = ref.read(playbackStopsProvider.notifier);
    _edges = claimWindowEdges(WindowEdges.none);
    // After the first frame: the strings it may need are an inherited
    // widget, which `initState` cannot ask for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  @override
  void dispose() {
    _cancel.cancel();
    _hideChrome?.cancel();
    _focus.dispose();
    _edges?.release();
    unawaited(restoreAppSystemUi());
    final saver = _saver;
    final at = _location?.position;
    final itemId = widget.item?.id;
    if (saver != null) {
      // Closed on the last page is read to the end.
      final sent = at != null && at.isFinished
          ? saver.finish(at)
          : saver.flush();
      saver.dispose();
      // The detail screen under this one, and the shelves, ask the server
      // again once it has heard.
      unawaited(
        sent.whenComplete(() {
          if (itemId != null) _stops.record(itemId);
        }),
      );
    }
    super.dispose();
  }

  Future<void> _open() async {
    final l10n = AppLocalizations.of(context);
    var item = widget.item;
    final active = ref.read(activeServerProvider);
    final profileId = widget.profileId ?? active?.profile.id;
    // The signed-in server, if the book is one of its own.
    final source = active != null && active.profile.id == profileId
        ? active
        : null;
    if (item == null || profileId == null) {
      setState(() => _stage = _Failed(l10n.readerFailed));
      return;
    }

    final pending = PendingBookPositions();
    if (source != null) {
      unawaited(pending.sendAll(source));
      // Opened from Downloads, the item is what the index kept, with no
      // position. The server's answer has it, if it gives one quickly. From
      // the detail screen the item is already that answer.
      if (widget.profileId != null || item.path == null) {
        try {
          item = await source.item(item.id).timeout(const Duration(seconds: 4));
        } on Object {
          // Offline enough: open where this device last was, or at the start.
        }
        if (!mounted) return;
      }
    }
    final book = item!;
    final waiting = await pending.get(profileId, book.id);

    File file;
    try {
      final downloaded = downloadedBook(ref, profileId, book.id);
      if (downloaded != null) {
        file = downloaded;
      } else if (source == null) {
        throw const BookFileException(BookFileFailure.unreachable, 'offline');
      } else {
        final files = await ref.read(bookFilesProvider.future);
        file = await files.fetch(
          source,
          book,
          cancel: _cancel,
          onProgress: (received, total) {
            if (!mounted || total == null || total <= 0) return;
            setState(() => _stage = _Fetching(received / total));
          },
        );
      }
    } on BookFileException catch (e) {
      debugPrint('Book not fetched: $e');
      if (!mounted) return;
      setState(
        () => _stage = _Failed(switch (e.failure) {
          BookFileFailure.forbidden => l10n.readerForbidden,
          BookFileFailure.unreachable => l10n.readerUnreachable,
          BookFileFailure.other => l10n.readerFailed,
        }),
      );
      return;
    } on Object catch (e) {
      debugPrint('Book not fetched: $e');
      if (mounted && !_cancel.isCancelled) {
        setState(() => _stage = _Failed(l10n.readerFailed));
      }
      return;
    }
    if (!mounted) return;

    // The file's own name is the last word on the format: the server's
    // `Path` is asked for on the detail fetch only.
    var format = book.bookFormat;
    if (format == BookFormat.unknown) format = BookFormat.fromPath(file.path);

    final webView = await ref.read(webViewReaderAvailableProvider.future);
    if (!mounted) return;
    final engine = _engineFor(format, webView: webView);
    if (engine == null) {
      setState(
        () => _stage = _Failed(
          format.family == BookFamily.reflowable
              ? l10n.readerNoWebView
              : l10n.readerUnsupported(
                  format == BookFormat.unknown ? '?' : format.label,
                ),
          file: canHandOffFiles ? file : null,
        ),
      );
      return;
    }

    _start = waiting == null
        ? BookPosition.fromTicks(book.positionTicks, format.family)
        : BookPosition.fromTicks(waiting.ticks, format.family);
    _saver = BookProgressSaver(
      source: source,
      profileId: profileId,
      itemId: book.id,
    );
    setState(() => _stage = _Reading(file, format, engine));
    _scheduleHide();
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    _hideChrome?.cancel();
    _chrome ? unawaited(restoreAppSystemUi()) : unawaited(enterImmersiveUi());
  }

  /// The chrome is up while the book opens, then gets out of the way.
  void _scheduleHide() {
    _hideChrome?.cancel();
    _hideChrome = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_chrome) return;
      setState(() => _chrome = false);
      unawaited(enterImmersiveUi());
    });
  }

  void _onLocation(ReaderLocation location) {
    if (!mounted) return;
    setState(() => _location = location);
    _saver?.update(location.position);
  }

  void _onFailed(String detail) {
    debugPrint('Reader engine failed: $detail');
    if (!mounted) return;
    final stage = _stage;
    setState(
      () => _stage = _Failed(
        AppLocalizations.of(context).readerFailed,
        file: canHandOffFiles && stage is _Reading ? stage.file : null,
      ),
    );
  }

  /// Arrow keys and the remote's d-pad for the engines Flutter draws. The
  /// WebView takes its own keys (kumo.js).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final engine = _engine;
    if (engine == null) return KeyEventResult.ignored;
    final rtl =
        ref.read(readerSettingsProvider).comicRightToLeft &&
        (_stage is _Reading && (_stage as _Reading).engine == _Engine.comic);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space) {
      unawaited(
        rtl && key == LogicalKeyboardKey.arrowRight
            ? engine.previous()
            : engine.next(),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      unawaited(
        rtl && key == LogicalKeyboardKey.arrowLeft
            ? engine.next()
            : engine.previous(),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      if (!_chrome) {
        _toggleChrome();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(readerSettingsProvider);
    final colours = settings.theme.colours(Theme.of(context).brightness);
    final item = widget.item;

    final body = switch (_stage) {
      _Fetching(:final fraction) => _Message(
        progress: true,
        fraction: fraction,
        text: fraction == null
            ? AppLocalizations.of(context).readerOpening
            : AppLocalizations.of(
                context,
              ).readerFetching((fraction * 100).round()),
        colour: colours.foreground,
      ),
      _Failed(:final message, :final file) => _Message(
        text: message,
        colour: colours.foreground,
        action: file == null
            ? null
            : FilledButton.tonalIcon(
                onPressed: () => launchUrl(Uri.file(file.path)),
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(AppLocalizations.of(context).openInAnotherApp),
              ),
      ),
      _Reading(:final file, :final format, :final engine) => _engineView(
        engine,
        ReaderEngineArgs(
          file: file,
          format: format,
          settings: settings,
          background: colours.background,
          start: _start,
          onReady: (e) {
            if (mounted) setState(() => _engine = e);
          },
          onLocation: _onLocation,
          onTap: _toggleChrome,
          onFailed: _onFailed,
        ),
      ),
    };

    final reading = _stage is _Reading;
    return Scaffold(
      backgroundColor: colours.background,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: body),
            // Up whenever there is no book to look at: a failure must keep
            // its way out.
            ReaderChrome(
              visible: _chrome || !reading,
              title: item?.title ?? '',
              location: _location,
              engine: _engine,
              background: colours.background,
              foreground: colours.foreground,
              comic: reading && (_stage as _Reading).engine == _Engine.comic,
              text: reading && (_stage as _Reading).engine == _Engine.web,
              onClose: () => context.pop(),
              onInteract: () => _hideChrome?.cancel(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _engineView(_Engine engine, ReaderEngineArgs args) => switch (engine) {
    _Engine.web => EpubEngineView(args: args),
    _Engine.pdf => PdfEngineView(args: args),
    _Engine.comic => ComicEngineView(args: args),
  };
}

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    required this.colour,
    this.progress = false,
    this.fraction,
    this.action,
  });

  final String text;
  final Color colour;
  final bool progress;
  final double? fraction;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(spacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (progress) ...<Widget>[
                fraction == null
                    ? const CircularProgressIndicator()
                    : LinearProgressIndicator(value: fraction),
                SizedBox(height: spacing.lg),
              ],
              Text(
                text,
                textAlign: TextAlign.center,
                style: context.texts.bodyLarge?.copyWith(color: colour),
              ),
              if (action != null) ...<Widget>[
                SizedBox(height: spacing.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

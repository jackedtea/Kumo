// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../servers/books.dart';
import 'reader_engine.dart';
import 'reader_server.dart';
import 'reader_settings.dart';

/// Whether this device can draw a reflowable book.
///
/// `webview_flutter` covers Android, iOS and macOS. Windows and Linux have
/// no implementation of it, so there an EPUB is handed to the system.
final webViewReaderAvailableProvider = FutureProvider<bool>((ref) async {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => true,
    _ => false,
  };
});

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// What the page is told about the settings.
Map<String, Object> _styleOf(ReaderSettings s, Color background) {
  final colours = s.theme.colours(
    background.computeLuminance() < 0.4 ? Brightness.dark : Brightness.light,
  );
  return <String, Object>{
    'fontSize': s.fontScale,
    'lineHeight': s.lineHeight,
    'margin': s.margin,
    'background': _hex(colours.background),
    'foreground': _hex(colours.foreground),
    'link': _hex(colours.link),
    'justify': s.justify,
  };
}

/// EPUB, MOBI/AZW3 and FB2, drawn by foliate-js in a WebView.
///
/// The page speaks through one JavaScript channel, `Kumo`, with
/// `{name, args}` messages (kumo.js); Dart answers with `kumo.*` calls.
class EpubEngineView extends ConsumerStatefulWidget {
  const EpubEngineView({super.key, required this.args});

  final ReaderEngineArgs args;

  @override
  ConsumerState<EpubEngineView> createState() => _EpubEngineViewState();
}

class _EpubEngineViewState extends ConsumerState<EpubEngineView>
    implements ReaderEngine {
  ReaderServer? _server;
  WebViewController? _web;
  List<ReaderTocEntry> _contents = const <ReaderTocEntry>[];
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final server = await ReaderServer.start(widget.args.file);
      if (!mounted) {
        await server.close();
        return;
      }
      final start = widget.args.start?.fraction;
      final page = server.pageUri(<String, String>{
        if (start != null && start > 0) 'start': '$start',
        'flow': widget.args.settings.scrolled ? 'scrolled' : 'paginated',
        'style': jsonEncode(
          _styleOf(widget.args.settings, widget.args.background),
        ),
      });

      final web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(widget.args.background)
        ..addJavaScriptChannel('Kumo', onMessageReceived: _onMessage)
        ..setNavigationDelegate(
          NavigationDelegate(
            // The book's own links open nothing outside it: a reader is not
            // a browser, and the only page it may show is its own.
            onNavigationRequest: (request) {
              final target = Uri.tryParse(request.url);
              final local =
                  target != null &&
                  target.host == '127.0.0.1' &&
                  target.port == page.port;
              return local
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onWebResourceError: (error) {
              if (error.isForMainFrame ?? false) {
                widget.args.onFailed(
                  '${error.errorType}: ${error.description}',
                );
              }
            },
          ),
        );
      await web.loadRequest(page);
      if (!mounted) {
        await server.close();
        return;
      }
      setState(() {
        _server = server;
        _web = web;
      });
    } on Object catch (e) {
      widget.args.onFailed('reader: $e');
    }
  }

  @override
  void didUpdateWidget(EpubEngineView old) {
    super.didUpdateWidget(old);
    final was = old.args.settings;
    final now = widget.args.settings;
    if (!_ready || was == now) return;
    if (was.scrolled != now.scrolled) {
      _run("kumo.setFlow('${now.scrolled ? 'scrolled' : 'paginated'}')");
    }
    unawaited(_web?.setBackgroundColor(widget.args.background));
    _run('kumo.setStyle(${jsonEncode(_styleOf(now, widget.args.background))})');
  }

  @override
  void dispose() {
    unawaited(_server?.close());
    super.dispose();
  }

  Future<void> _run(String js) async {
    try {
      await _web?.runJavaScript(js);
    } on Object catch (e) {
      debugPrint('Reader script failed: $e');
    }
  }

  @override
  Future<void> next() => _run('kumo.next()');

  @override
  Future<void> previous() => _run('kumo.prev()');

  @override
  Future<void> goToFraction(double fraction) =>
      _run('kumo.goToFraction(${fraction.clamp(0.0, 1.0)})');

  @override
  Future<void> goToEntry(ReaderTocEntry entry) {
    final href = entry.href;
    if (href == null) return Future<void>.value();
    return _run('kumo.goTo(${jsonEncode(href)})');
  }

  @override
  List<ReaderTocEntry> get contents => _contents;

  @override
  int? get pageCount => null;

  void _onMessage(JavaScriptMessage message) {
    final Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final info = decoded['args'];
    switch (decoded['name']) {
      case 'ready':
        _onReady(info);
      case 'relocate':
        _onRelocate(info);
      case 'tap':
        widget.args.onTap();
      case 'failed':
        widget.args.onFailed('${info ?? 'unknown'}');
    }
  }

  void _onReady(Object? info) {
    final toc = info is Map ? info['toc'] : null;
    _contents = <ReaderTocEntry>[
      if (toc is List)
        for (final Object? e in toc)
          if (e is Map && (e['label'] as String? ?? '').isNotEmpty)
            ReaderTocEntry(
              label: e['label'] as String,
              href: e['href'] as String?,
              depth: (e['depth'] as num?)?.toInt() ?? 0,
            ),
    ];
    _ready = true;
    widget.args.onReady(this);
  }

  void _onRelocate(Object? info) {
    if (info is! Map) return;
    final fraction = (info['fraction'] as num?)?.toDouble();
    if (fraction == null) return;
    widget.args.onLocation(
      ReaderLocation(
        position: BookPosition.fraction(fraction.clamp(0.0, 1.0)),
        chapter: (info['chapter'] as String?)?.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return ColoredBox(
      color: widget.args.background,
      child: web == null
          ? const Center(child: CircularProgressIndicator())
          : WebViewWidget(controller: web),
    );
  }
}

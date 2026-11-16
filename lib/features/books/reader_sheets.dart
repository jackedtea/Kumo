// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../servers/books.dart';
import 'reader_engine.dart';
import 'reader_settings.dart';

/// "42 %", or "Page 120 of 300" for a paged book.
String readerPositionLabel(AppLocalizations l10n, BookPosition position) {
  final page = position.pageIndex;
  final count = position.pageCount;
  if (page != null) {
    return count == null || count <= 0
        ? l10n.bookPage(page + 1)
        : l10n.bookPageOf(page + 1, count);
  }
  return l10n.percent(((position.fraction ?? 0) * 100).round());
}

/// The reader's bars: title and buttons on top, the slider at the foot.
///
/// Drawn over the book, never beside it — a page that shifts every time the
/// chrome comes and goes reflows the text under the reader's eye.
class ReaderChrome extends StatefulWidget {
  const ReaderChrome({
    super.key,
    required this.visible,
    required this.title,
    required this.location,
    required this.engine,
    required this.background,
    required this.foreground,
    required this.onClose,
    required this.onInteract,
    this.comic = false,
    this.text = false,
  });

  final bool visible;
  final String title;
  final ReaderLocation? location;
  final ReaderEngine? engine;
  final Color background;
  final Color foreground;
  final VoidCallback onClose;

  /// Something in the chrome was touched: the timer that hides it stops.
  final VoidCallback onInteract;

  /// Which settings apply: the comic ones, or the text ones.
  final bool comic;
  final bool text;

  @override
  State<ReaderChrome> createState() => _ReaderChromeState();
}

class _ReaderChromeState extends State<ReaderChrome> {
  /// The slider while a thumb is on it. The book only moves on release:
  /// jumping a WebView through two hundred chapters as the thumb passes
  /// them is a stutter, not a preview.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final spacing = context.spacing;
    final engine = widget.engine;
    final location = widget.location;
    final fg = widget.foreground;
    final bar = widget.background.withValues(alpha: 0.96);

    final pages = engine?.pageCount;
    // The slider runs over the pages for a paged book (first page 0, last
    // page 1) and over the text for a reflowable one.
    final page = location?.position.pageIndex;
    final progress = page != null && pages != null && pages > 1
        ? page / (pages - 1)
        : location?.position.fraction;
    final label = location == null
        ? ''
        : readerPositionLabel(l10n, location.position);

    final top = Material(
      color: bar,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: spacing.xs),
          child: Row(
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                color: fg,
                tooltip: l10n.actionBack,
                onPressed: widget.onClose,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.titleMedium?.copyWith(color: fg),
                    ),
                    if (location?.chapter?.isNotEmpty ?? false)
                      Text(
                        location!.chapter!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall?.copyWith(
                          color: fg.withValues(alpha: 0.7),
                        ),
                      ),
                  ],
                ),
              ),
              if (engine != null && engine.contents.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.toc_rounded),
                  color: fg,
                  tooltip: l10n.readerContents,
                  onPressed: () {
                    widget.onInteract();
                    showReaderContents(context, engine);
                  },
                ),
              if (widget.comic || widget.text)
                IconButton(
                  icon: const Icon(Icons.text_format_rounded),
                  color: fg,
                  tooltip: l10n.readerSettings,
                  onPressed: () {
                    widget.onInteract();
                    showReaderSettings(
                      context,
                      comic: widget.comic,
                      text: widget.text,
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );

    final bottom = Material(
      color: bar,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            spacing.lg,
            spacing.xs,
            spacing.lg,
            spacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Slider(
                  value: (_dragging ?? progress ?? 0).clamp(0.0, 1.0),
                  divisions: pages != null && pages > 1 ? pages - 1 : null,
                  onChanged: engine == null
                      ? null
                      : (v) {
                          widget.onInteract();
                          setState(() => _dragging = v);
                        },
                  onChangeEnd: engine == null
                      ? null
                      : (v) {
                          setState(() => _dragging = null);
                          unawaited(engine.goToFraction(v));
                        },
                ),
              ),
              SizedBox(width: spacing.sm),
              Text(
                _dragging == null
                    ? label
                    : pages != null && pages > 0
                    ? l10n.bookPageOf(
                        (_dragging! * (pages - 1)).round() + 1,
                        pages,
                      )
                    : l10n.percent((_dragging! * 100).round()),
                style: context.texts.labelMedium?.copyWith(color: fg),
              ),
            ],
          ),
        ),
      ),
    );

    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: Column(
          children: <Widget>[top, const Spacer(), if (engine != null) bottom],
        ),
      ),
    );
  }
}

/// The table of contents, as a sheet. A tap goes there.
Future<void> showReaderContents(BuildContext context, ReaderEngine engine) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) {
        final entries = engine.contents;
        if (entries.isEmpty) {
          return Center(child: Text(l10n.readerNoContents));
        }
        return ListView.builder(
          controller: scroll,
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final e = entries[i];
            return ListTile(
              contentPadding: EdgeInsets.only(
                left: context.spacing.lg + e.depth * context.spacing.lg,
                right: context.spacing.lg,
              ),
              title: Text(
                e.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: e.page == null ? null : Text('${e.page! + 1}'),
              onTap: () {
                Navigator.of(context).pop();
                unawaited(engine.goToEntry(e));
              },
            );
          },
        );
      },
    ),
  );
}

/// How the book looks: colours, type and layout for text, order for comics.
Future<void> showReaderSettings(
  BuildContext context, {
  required bool comic,
  required bool text,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _ReaderSettingsSheet(comic: comic, text: text),
  );
}

class _ReaderSettingsSheet extends ConsumerWidget {
  const _ReaderSettingsSheet({required this.comic, required this.text});

  final bool comic;
  final bool text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final spacing = context.spacing;
    final s = ref.watch(readerSettingsProvider);
    final c = ref.read(readerSettingsProvider.notifier);

    String themeName(ReaderTheme t) => switch (t) {
      ReaderTheme.system => l10n.readerThemeSystem,
      ReaderTheme.light => l10n.readerThemeLight,
      ReaderTheme.sepia => l10n.readerThemeSepia,
      ReaderTheme.dark => l10n.readerThemeDark,
      ReaderTheme.black => l10n.readerThemeBlack,
    };

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        spacing.lg,
        0,
        spacing.lg,
        spacing.xl + context.systemBottomInset,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(l10n.readerSettings, style: context.texts.titleMedium),
          SizedBox(height: spacing.md),
          Text(l10n.readerTheme, style: context.texts.labelLarge),
          SizedBox(height: spacing.sm),
          Wrap(
            spacing: spacing.sm,
            runSpacing: spacing.sm,
            children: <Widget>[
              for (final ReaderTheme t in ReaderTheme.values)
                ChoiceChip(
                  label: Text(themeName(t)),
                  selected: s.theme == t,
                  onSelected: (_) => c.update((x) => x.copyWith(theme: t)),
                ),
            ],
          ),
          if (text) ...<Widget>[
            SizedBox(height: spacing.lg),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.readerFontSize,
                    style: context.texts.labelLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.text_decrease_rounded),
                  tooltip: l10n.readerSmaller,
                  onPressed: s.fontScale <= ReaderSettings.minFont
                      ? null
                      : () => c.update(
                          (x) => x.copyWith(fontScale: x.fontScale - 10),
                        ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    l10n.percent(s.fontScale),
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.text_increase_rounded),
                  tooltip: l10n.readerLarger,
                  onPressed: s.fontScale >= ReaderSettings.maxFont
                      ? null
                      : () => c.update(
                          (x) => x.copyWith(fontScale: x.fontScale + 10),
                        ),
                ),
              ],
            ),
            Text(l10n.readerLineHeight, style: context.texts.labelLarge),
            Slider(
              value: s.lineHeight,
              min: 1.0,
              max: 2.4,
              divisions: 14,
              label: s.lineHeight.toStringAsFixed(1),
              onChanged: (v) => c.update((x) => x.copyWith(lineHeight: v)),
            ),
            Text(l10n.readerMargins, style: context.texts.labelLarge),
            Slider(
              value: s.margin.toDouble(),
              min: 0,
              max: 20,
              divisions: 10,
              label: '${s.margin}',
              onChanged: (v) => c.update((x) => x.copyWith(margin: v.round())),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.readerScrolled),
              value: s.scrolled,
              onChanged: (v) => c.update((x) => x.copyWith(scrolled: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.readerJustify),
              value: s.justify,
              onChanged: (v) => c.update((x) => x.copyWith(justify: v)),
            ),
          ],
          if (comic) ...<Widget>[
            SizedBox(height: spacing.md),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.comicRightToLeft),
              value: s.comicRightToLeft,
              onChanged: (v) =>
                  c.update((x) => x.copyWith(comicRightToLeft: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.comicSpread),
              value: s.comicSpread,
              onChanged: (v) => c.update((x) => x.copyWith(comicSpread: v)),
            ),
          ],
        ],
      ),
    );
  }
}

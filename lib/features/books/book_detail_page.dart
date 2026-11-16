// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../servers/books.dart';
import '../../servers/media_library_source.dart';
import '../../widgets/collapsing_header.dart';
import '../../widgets/detail_header.dart';
import '../../widgets/section_header.dart';
import '../player/playback_state.dart';
import '../servers/detail_sections.dart';
import '../servers/item_action_row.dart';
import '../servers/server_library.dart';
import '../servers/shelves.dart';
import 'book_reader_page.dart';
import 'reader_sheets.dart';

/// The other volumes of a book's series, in order, without the book itself.
final bookSeriesProvider = FutureProvider.autoDispose
    .family<List<ServerItem>, ({String parentId, String series, String self})>((
      ref,
      key,
    ) async {
      final source = ref.watch(activeServerProvider);
      if (source == null) return const <ServerItem>[];
      ref.watch(playbackStopsProvider);
      try {
        final all = await source.bookSeries(key.parentId, key.series);
        return <ServerItem>[
          for (final ServerItem b in all)
            if (b.id != key.self) b,
        ];
      } on ServerException {
        return const <ServerItem>[];
      }
    });

/// One book, read or listened to.
///
/// The movie screen's layout — backdrop, cover hanging off it, facts beside
/// — because a book opened from a shelf should look like a film opened from
/// the next one. What differs is the verb: Read, with the place it will open
/// at, and for an audiobook Listen through the music player.
class BookDetailPage extends ConsumerStatefulWidget {
  const BookDetailPage({super.key, this.itemId});

  final String? itemId;

  @override
  ConsumerState<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends ConsumerState<BookDetailPage> {
  bool _overviewExpanded = false;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;
    final l10n = AppLocalizations.of(context);
    final itemId = widget.itemId;

    final request = itemId == null
        ? const AsyncValue<ServerItem?>.data(null)
        : ref.watch(serverItemProvider(itemId));
    final item = request.value;
    if (item == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: l10n.actionBack,
            onPressed: () => context.pop(),
          ),
        ),
        body: Center(
          child: request.isLoading
              ? const CircularProgressIndicator()
              : Text(l10n.nothingToPlay),
        ),
      );
    }

    final heard = item.kind == ServerItemKind.audioBook;
    final position = item.bookPosition;
    final started = heard ? item.isStarted : position != null;
    final padding = spacing.screenPadding(context.windowSize);
    final compact = context.windowSize == WindowSize.compact;

    void open() => heard
        ? playServerItem(context, ref, item.id)
        : openBookReader(context, item);
    void startOver() => playServerItem(context, ref, item.id, fromStart: true);

    final verb = heard
        ? (started ? l10n.continueListening : l10n.listen)
        : (started ? l10n.continueReading : l10n.read);
    final icon = heard ? Icons.headphones_rounded : Icons.menu_book_rounded;

    final where = heard
        ? (started ? remainingLabel(item, l10n) : null)
        : position == null
        ? null
        : readerPositionLabel(l10n, position);

    final actions = ItemActionIcons(
      item: item,
      primary: false,
      alignment: compact ? WrapAlignment.center : WrapAlignment.start,
      onPlay: open,
      playlistIds: heard ? <String>[item.id] : const <String>[],
    );

    final series = item.seriesTitle;
    final parent = item.parentId;

    return Scaffold(
      bottomNavigationBar: compact
          ? ItemPrimaryActionBar(
              item: item,
              label: verb,
              caption: where,
              icon: icon,
              onPlay: open,
              onStartOver: heard ? startOver : null,
            )
          : null,
      body: CustomScrollView(
        slivers: <Widget>[
          CollapsingHeaderSliver(
            title: item.title,
            header: DetailHeader(
              seed: item.title,
              title: item.title,
              originalTitle: item.originalTitle,
              caption: item.authorLine,
              backdropUrl: backdropUrlFor(
                ref,
                item,
                maxWidth: compact ? 1000 : 1920,
              ),
              posterUrl: artUrlFor(ref, item, maxWidth: 400),
              facts: _facts(item, l10n),
              actionBar: compact
                  ? actions
                  : Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: spacing.sm,
                      runSpacing: spacing.sm,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: open,
                          icon: Icon(icon),
                          label: Text(where == null ? verb : '$verb · $where'),
                        ),
                        actions,
                      ],
                    ),
              aside: compact ? null : _aside(item),
            ),
          ),
          if (started)
            SliverToBoxAdapter(
              child: Padding(
                padding: padding.copyWith(top: spacing.md, bottom: 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: heard ? item.watchedFraction : position?.progress,
                    minHeight: 4,
                    backgroundColor: context.colors.surfaceContainerHighest,
                  ),
                ),
              ),
            ),
          if (compact && (item.overview?.isNotEmpty ?? false))
            SliverToBoxAdapter(
              child: Padding(
                padding: padding.copyWith(top: spacing.lg),
                child: _Overview(
                  text: item.overview!,
                  expanded: _overviewExpanded,
                  onToggle: () =>
                      setState(() => _overviewExpanded = !_overviewExpanded),
                ),
              ),
            ),
          if (compact && item.genres.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: spacing.md),
                child: TagStrip(tags: item.genres, padding: padding),
              ),
            ),
          if (series != null && series.isNotEmpty && parent != null)
            SliverToBoxAdapter(
              child: _SeriesShelf(
                parentId: parent,
                series: series,
                self: item.id,
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: spacing.xl * 2 + context.systemBottomInset),
          ),
        ],
      ),
    );
  }

  List<Widget> _facts(ServerItem item, AppLocalizations l10n) {
    final style = context.texts.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    final series = item.seriesTitle;
    final volume = item.volumeNumber;
    final format = item.bookFormat;
    return <Widget>[
      if (series != null && series.isNotEmpty)
        Text(
          volume == null ? series : '$series · ${l10n.bookVolume(volume)}',
          style: style,
        ),
      if (item.year != null) Text('${item.year}', style: style),
      if (item.kind == ServerItemKind.audioBook && item.runtime != null)
        Text(durationLabel(item.runtime!), style: style),
      if (format != BookFormat.unknown)
        CertificateBox(certificate: format.label),
      if (item.studios.isNotEmpty) Text(item.studios.first, style: style),
    ];
  }

  Widget? _aside(ServerItem item) {
    final overview = item.overview ?? '';
    if (overview.isEmpty && item.genres.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (overview.isNotEmpty)
          _Overview(
            text: overview,
            lines: 6,
            expanded: _overviewExpanded,
            onToggle: () =>
                setState(() => _overviewExpanded = !_overviewExpanded),
          ),
        if (item.genres.isNotEmpty) ...<Widget>[
          SizedBox(height: context.spacing.md),
          TagStrip(tags: item.genres),
        ],
      ],
    );
  }
}

class _SeriesShelf extends ConsumerWidget {
  const _SeriesShelf({
    required this.parentId,
    required this.series,
    required this.self,
  });

  final String parentId;
  final String series;
  final String self;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volumes = ref.watch(
      bookSeriesProvider((parentId: parentId, series: series, self: self)),
    );
    // Nothing at all until there is something: a heading over an empty row
    // reads as a shelf that failed.
    if (volumes.value?.isEmpty ?? true) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: context.spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SectionHeader(
            title: AppLocalizations.of(context).moreInSeries(series),
          ),
          ServerPosterShelf(items: volumes),
        ],
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({
    required this.text,
    required this.expanded,
    required this.onToggle,
    this.lines = 4,
  });

  final String text;
  final int lines;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            text,
            maxLines: expanded ? null : lines,
            overflow: expanded ? null : TextOverflow.ellipsis,
            style: context.texts.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Text(
            expanded ? l10n.less : l10n.more,
            style: context.texts.bodyMedium?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

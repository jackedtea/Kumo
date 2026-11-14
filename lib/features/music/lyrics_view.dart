// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/tokens.dart';
import '../../servers/media_library_source.dart';
import '../player/playback_controller.dart';
import '../servers/server_library.dart';

/// The words of one song, or null when it has none or no server is open.
///
/// Dropped with Now playing: asking again for the next visit costs one small
/// request, and a cache of every song ever opened would cost more.
final songLyricsProvider =
    FutureProvider.autoDispose.family<Lyrics?, String>((ref, itemId) async {
  final source = ref.watch(activeServerProvider);
  if (source == null) return null;
  return source.lyrics(itemId);
});

/// A song's words in place of its cover.
///
/// Timed lyrics follow the song: the line being sung is drawn in the primary
/// colour and kept a little above the middle, and tapping a line seeks to it.
/// Plain lyrics are only text to scroll.
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({super.key, required this.lyrics});

  final Lyrics lyrics;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  late List<GlobalKey> _keys = _keysFor(widget.lyrics);

  static List<GlobalKey> _keysFor(Lyrics lyrics) => <GlobalKey>[
        for (var i = 0; i < lyrics.lines.length; i++) GlobalKey(),
      ];

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (!identical(old.lyrics, widget.lyrics)) {
      _keys = _keysFor(widget.lyrics);
    }
  }

  void _follow(int? line) {
    if (line == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _keys[line].currentContext;
      if (target == null || !target.mounted) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.4,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    final lines = lyrics.lines;
    final spacing = context.spacing;
    final scheme = context.colors;
    final base = context.texts.titleMedium;

    // Rebuilt when the line changes, not on every position tick.
    final current = lyrics.synced
        ? ref.watch(
            playbackControllerProvider.select(
              (s) => currentLyricLine(lines, s.position),
            ),
          )
        : null;

    if (lyrics.synced) {
      ref.listen<int?>(
        playbackControllerProvider.select(
          (s) => currentLyricLine(lines, s.position),
        ),
        (_, next) => _follow(next),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(vertical: spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < lines.length; i++)
            _Line(
              key: _keys[i],
              // An empty timed line is an instrumental break: a note keeps it
              // visible as the place the song has reached.
              text: lines[i].text.trim().isEmpty && lyrics.synced
                  ? '♪'
                  : lines[i].text,
              style: base?.copyWith(
                fontWeight: i == current ? FontWeight.w600 : FontWeight.w400,
                color: !lyrics.synced
                    ? scheme.onSurface
                    : i == current
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(
                            alpha: current != null && i < current ? 0.5 : 0.8,
                          ),
              ),
              onTap: lyrics.synced
                  ? () => ref
                      .read(playbackControllerProvider.notifier)
                      .seek(lines[i].start!)
                  : null,
            ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({super.key, required this.text, this.style, this.onTap});

  final String text;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;
    final child = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.xs,
      ),
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 200),
        style: style ?? const TextStyle(),
        textAlign: TextAlign.center,
        child: Text(text, textAlign: TextAlign.center),
      ),
    );

    if (onTap == null) return child;
    return InkWell(
      borderRadius: context.radii.cardAll,
      onTap: onTap,
      child: child,
    );
  }
}

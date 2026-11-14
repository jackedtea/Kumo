// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter_test/flutter_test.dart';

import 'package:kumo/features/player/gapless.dart';
import 'package:kumo/features/player/playback_state.dart';
import 'package:kumo/features/settings/player_settings.dart';
import 'package:kumo/servers/jellyfin_dto.dart';
import 'package:kumo/servers/media_library_source.dart';
import 'package:kumo/sources/media_source.dart';

MediaRef _ref(String id) => MediaRef(sourceId: 'p1', itemId: id, title: id);

PlaybackQueue _queue({
  int index = 0,
  PlaybackQueueKind kind = PlaybackQueueKind.music,
}) =>
    PlaybackQueue(
      items: <MediaRef>[for (final String id in 'abc'.split('')) _ref(id)],
      index: index,
      kind: kind,
    );

/// Ticks, as Jellyfin counts: ten thousand to the millisecond.
int _ticks(int seconds) => seconds * 10000000;

void main() {
  group('lyrics from /Audio/{id}/Lyrics', () {
    test('timed lines come back sorted, in order of singing', () {
      final lyrics = lyricsFromJson(<String, dynamic>{
        'Metadata': <String, dynamic>{'IsSynced': true},
        'Lyrics': <Map<String, dynamic>>[
          {'Text': 'second', 'Start': _ticks(12)},
          {'Text': 'first', 'Start': _ticks(3)},
          {'Text': '', 'Start': _ticks(20)},
        ],
      })!;

      expect(lyrics.synced, isTrue);
      expect(lyrics.lines.map((l) => l.text), <String>['first', 'second', '']);
      expect(lyrics.lines.first.start, const Duration(seconds: 3));
    });

    test('plain lyrics have no times and are not followed', () {
      final lyrics = lyricsFromJson(<String, dynamic>{
        'Lyrics': <Map<String, dynamic>>[
          {'Text': 'one'},
          {'Text': 'two'},
        ],
      })!;

      expect(lyrics.synced, isFalse);
      expect(lyrics.lines.length, 2);
    });

    test('a line at 0:00 is timed, not untimed', () {
      // Zero is the first beat of the song, the same reason segments parse
      // positions differently from runtimes.
      final lyrics = lyricsFromJson(<String, dynamic>{
        'Lyrics': <Map<String, dynamic>>[
          {'Text': 'opening', 'Start': 0},
          {'Text': 'next', 'Start': _ticks(4)},
        ],
      })!;

      expect(lyrics.synced, isTrue);
      expect(lyrics.lines.first.start, Duration.zero);
    });

    test('no words at all is no lyrics', () {
      expect(lyricsFromJson(<String, dynamic>{}), isNull);
      expect(
        lyricsFromJson(<String, dynamic>{
          'Lyrics': <Map<String, dynamic>>[
            {'Text': '  '},
          ],
        }),
        isNull,
      );
    });

    test('the current line is the last one started', () {
      const lines = <LyricLine>[
        LyricLine('a', start: Duration(seconds: 2)),
        LyricLine('b', start: Duration(seconds: 5)),
        LyricLine('c', start: Duration(seconds: 9)),
      ];

      expect(currentLyricLine(lines, const Duration(seconds: 1)), isNull);
      expect(currentLyricLine(lines, const Duration(seconds: 2)), 0);
      expect(currentLyricLine(lines, const Duration(seconds: 8)), 1);
      expect(currentLyricLine(lines, const Duration(minutes: 3)), 2);
    });
  });

  group('which song is handed to mpv ahead of time', () {
    PlaybackQueue? next(
      PlaybackQueue queue, {
      LoopMode loop = LoopMode.off,
      GaplessAudio gapless = GaplessAudio.automatic,
      bool stopAfter = false,
    }) =>
        gaplessNext(
          queue,
          loop: loop,
          gapless: gapless,
          stopAfterCurrent: stopAfter,
        );

    test('the next song of a music queue', () {
      final queue = next(_queue())!;
      expect(queue.index, 1);
      expect(queue.current, _ref('b'));
    });

    test('nothing for a series, which waits on its own prompt', () {
      expect(next(_queue(kind: PlaybackQueueKind.series)), isNull);
    });

    test('nothing with gapless off, on repeat-one, or stopping after', () {
      expect(next(_queue(), gapless: GaplessAudio.off), isNull);
      expect(next(_queue(), loop: LoopMode.one), isNull);
      expect(next(_queue(), stopAfter: true), isNull);
    });

    test('off the end only on repeat-all, back to the top', () {
      expect(next(_queue(index: 2)), isNull);

      final wrapped = next(_queue(index: 2), loop: LoopMode.all)!;
      expect(wrapped.index, 0);
      expect(wrapped.current, _ref('a'));
    });
  });

  group('ReplayGain', () {
    test('defaults to off and survives a round trip', () {
      expect(const PlayerSettings().replayGain, ReplayGain.off);

      final saved = const PlayerSettings(replayGain: ReplayGain.album).toJson();
      expect(PlayerSettings.fromJson(saved).replayGain, ReplayGain.album);
    });

    test('an unknown stored value falls back to off', () {
      expect(
        PlayerSettings.fromJson(<String, dynamic>{'replayGain': 'loud'})
            .replayGain,
        ReplayGain.off,
      );
    });

    test('maps onto what mpv calls each mode', () {
      expect(ReplayGain.off.mpvValue, 'no');
      expect(ReplayGain.track.mpvValue, 'track');
      expect(ReplayGain.album.mpvValue, 'album');
    });
  });

  group('stop after this song and the sleep timer', () {
    test('both live on the playback state and clear independently', () {
      final at = DateTime(2026, 11, 14, 23, 15);
      final state = const PlaybackState().copyWith(
        stopAfterCurrent: true,
        sleepAt: at,
      );

      expect(state.stopAfterCurrent, isTrue);
      expect(state.sleepAt, at);
      expect(state.copyWith(clearSleepAt: true).sleepAt, isNull);
      expect(state.copyWith(clearSleepAt: true).stopAfterCurrent, isTrue);
      expect(state.copyWith(position: Duration.zero).sleepAt, at);
    });
  });
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter_test/flutter_test.dart';

import 'package:kumo/features/player/segment_skipper.dart';
import 'package:kumo/features/settings/player_settings.dart';
import 'package:kumo/servers/media_library_source.dart';
import 'package:kumo/sources/media_source.dart';

const _intro = MediaSegment(
  kind: MediaSegmentKind.intro,
  start: Duration(seconds: 60),
  end: Duration(seconds: 150),
);

const _outro = MediaSegment(
  kind: MediaSegmentKind.outro,
  start: Duration(minutes: 22),
  end: Duration(minutes: 24),
);

/// Everything set to skip itself, which is the setting under test.
SegmentAction _skipEverything(MediaSegmentKind _) => SegmentAction.skip;

MediaSegment? decide({
  List<MediaSegment> segments = const <MediaSegment>[_intro, _outro],
  Duration? previous,
  required Duration now,
  SegmentAction Function(MediaSegmentKind) actionFor = _skipEverything,
  Set<MediaSegment> alreadySkipped = const <MediaSegment>{},
  Duration? openedAt,
}) {
  return segmentToSkip(
    segments: segments,
    previous: previous,
    now: now,
    actionFor: actionFor,
    alreadySkipped: alreadySkipped,
    openedAt: openedAt,
  );
}

void main() {
  group('playing into a segment', () {
    test('the tick that crosses the start is the one that skips', () {
      expect(
        decide(
          previous: const Duration(seconds: 59, milliseconds: 800),
          now: const Duration(seconds: 60, milliseconds: 100),
        ),
        _intro,
      );
    });

    test('a later tick inside the same segment does nothing', () {
      // The crossing already happened; acting again would seek a viewer who
      // rewound a few seconds on purpose.
      expect(
        decide(
          previous: const Duration(seconds: 70),
          now: const Duration(seconds: 70, milliseconds: 300),
        ),
        isNull,
      );
    });

    test('a segment starting at zero is crossed on the first real tick', () {
      // The commonest intro there is, and the one an "is the start greater
      // than zero" guard would silently drop.
      const opening = MediaSegment(
        kind: MediaSegmentKind.intro,
        start: Duration.zero,
        end: Duration(seconds: 90),
      );

      expect(
        decide(
          segments: const <MediaSegment>[opening],
          previous: const Duration(milliseconds: -1),
          now: Duration.zero,
        ),
        opening,
      );
    });
  });

  group('seeking into a segment', () {
    test('a jump into the middle of one is left alone', () {
      // Someone who dragged the scrubber into the opening titles meant to be
      // there.
      expect(
        decide(previous: Duration.zero, now: const Duration(seconds: 90)),
        isNull,
      );
    });

    test('a jump that lands exactly on the start is still a jump', () {
      expect(
        decide(previous: Duration.zero, now: const Duration(seconds: 60)),
        isNull,
      );
    });

    test('seeking backwards never skips', () {
      expect(
        decide(
          previous: const Duration(minutes: 5),
          now: const Duration(seconds: 61),
        ),
        isNull,
      );
    });

    test('the first tick of a file has nothing to compare against', () {
      // A film resuming at 22 minutes would otherwise look like it had just
      // played into the closing credits.
      expect(decide(previous: null, now: const Duration(minutes: 22)), isNull);
    });
  });

  group('what the user asked for', () {
    test('a kind set to be offered is left for the pill', () {
      expect(
        decide(
          previous: const Duration(seconds: 59),
          now: const Duration(seconds: 61),
          actionFor: (_) => SegmentAction.askToSkip,
        ),
        isNull,
      );
    });

    test('a kind set to nothing is watched', () {
      expect(
        decide(
          previous: const Duration(seconds: 59),
          now: const Duration(seconds: 61),
          actionFor: (_) => SegmentAction.nothing,
        ),
        isNull,
      );
    });

    test('only the kind that was set to skip is skipped', () {
      SegmentAction outroOnly(MediaSegmentKind kind) =>
          kind == MediaSegmentKind.outro
          ? SegmentAction.skip
          : SegmentAction.nothing;

      expect(
        decide(
          previous: const Duration(seconds: 59),
          now: const Duration(seconds: 61),
          actionFor: outroOnly,
        ),
        isNull,
      );
      expect(
        decide(
          previous: const Duration(minutes: 21, seconds: 59),
          now: const Duration(minutes: 22, seconds: 1),
          actionFor: outroOnly,
        ),
        _outro,
      );
    });
  });

  group('guards', () {
    test('a segment already skipped is not skipped again', () {
      // An auto-skip lands a millisecond from still being inside the segment.
      expect(
        decide(
          previous: const Duration(seconds: 59),
          now: const Duration(seconds: 61),
          alreadySkipped: <MediaSegment>{_intro},
        ),
        isNull,
      );
    });

    test('a stretch too short to be worth the stall is left alone', () {
      const blink = MediaSegment(
        kind: MediaSegmentKind.intro,
        start: Duration(seconds: 60),
        end: Duration(seconds: 60, milliseconds: 400),
      );

      expect(
        decide(
          segments: const <MediaSegment>[blink],
          previous: const Duration(seconds: 59),
          now: const Duration(seconds: 61),
        ),
        isNull,
      );
    });

    test('a file with no segments decides nothing', () {
      expect(
        decide(
          segments: const <MediaSegment>[],
          previous: const Duration(seconds: 59),
          now: const Duration(seconds: 61),
        ),
        isNull,
      );
    });
  });

  group('the first tick of a file', () {
    const opening = MediaSegment(
      kind: MediaSegmentKind.intro,
      start: Duration.zero,
      end: Duration(seconds: 90),
    );

    test('an intro at 0:00 is skipped when the file opens at 0:00', () {
      // The first report has nothing before it and every later one is
      // already inside, so without the opening position this never fired.
      expect(
        decide(
          segments: const <MediaSegment>[opening],
          now: Duration.zero,
          openedAt: Duration.zero,
        ),
        opening,
      );
    });

    test('a resume inside a segment does not skip it', () {
      expect(
        decide(
          segments: const <MediaSegment>[opening],
          now: const Duration(seconds: 40),
          openedAt: const Duration(seconds: 40),
        ),
        isNull,
      );
    });

    test('a stale 0:00 before a resume seek lands is ignored', () {
      expect(
        decide(
          segments: const <MediaSegment>[opening],
          now: Duration.zero,
          openedAt: const Duration(minutes: 12),
        ),
        isNull,
      );
    });
  });

  group('chapter titles', () {
    test('OP, ED and their spellings are recognised', () {
      expect(chapterKind('OP'), MediaSegmentKind.intro);
      expect(chapterKind('op1'), MediaSegmentKind.intro);
      expect(chapterKind('Opening'), MediaSegmentKind.intro);
      expect(chapterKind('OP - Song Title'), MediaSegmentKind.intro);
      expect(chapterKind('Intro'), MediaSegmentKind.intro);
      expect(chapterKind('ED'), MediaSegmentKind.outro);
      expect(chapterKind('ED 2'), MediaSegmentKind.outro);
      expect(chapterKind('Ending: Artist'), MediaSegmentKind.outro);
      expect(chapterKind('End Credits'), MediaSegmentKind.outro);
      expect(chapterKind('Credits'), MediaSegmentKind.outro);
      expect(chapterKind('Preview'), MediaSegmentKind.preview);
      expect(chapterKind('Recap'), MediaSegmentKind.recap);
    });

    test('ordinary chapters are left alone', () {
      expect(chapterKind('Chapter 1'), isNull);
      expect(chapterKind('Part A'), isNull);
      expect(chapterKind('Option'), isNull);
      expect(chapterKind('Edward'), isNull);
      expect(chapterKind('Introduction'), isNull);
      expect(chapterKind('Avant'), isNull);
      expect(chapterKind(''), isNull);
    });

    test('an anime episode becomes an intro and an outro', () {
      const chapters = <MediaChapter>[
        MediaChapter(
          title: 'Avant',
          start: Duration.zero,
          end: Duration(minutes: 1),
        ),
        MediaChapter(
          title: 'OP',
          start: Duration(minutes: 1),
          end: Duration(minutes: 2, seconds: 30),
        ),
        MediaChapter(
          title: 'Part A',
          start: Duration(minutes: 2, seconds: 30),
          end: Duration(minutes: 21),
        ),
        MediaChapter(
          title: 'ED',
          start: Duration(minutes: 21),
          end: Duration(minutes: 22, seconds: 30),
        ),
      ];

      expect(segmentsFromChapters(chapters), const <MediaSegment>[
        MediaSegment(
          kind: MediaSegmentKind.intro,
          start: Duration(minutes: 1),
          end: Duration(minutes: 2, seconds: 30),
        ),
        MediaSegment(
          kind: MediaSegmentKind.outro,
          start: Duration(minutes: 21),
          end: Duration(minutes: 22, seconds: 30),
        ),
      ]);
    });
  });

  group('skipLabelFor', () {
    MediaChapter ch(String title, int from, int to) => MediaChapter(
      title: title,
      start: Duration(seconds: from),
      end: Duration(seconds: to),
    );
    MediaSegment seg(MediaSegmentKind kind, int from, int to) => MediaSegment(
      kind: kind,
      start: Duration(seconds: from),
      end: Duration(seconds: to),
    );

    test('an intro under a chapter titled OP is an opening', () {
      expect(
        skipLabelFor(seg(MediaSegmentKind.intro, 60, 150), [
          ch('Prologue', 0, 60),
          ch('OP', 60, 150),
          ch('Part A', 150, 700),
        ]),
        SkipLabel.opening,
      );
    });

    test('an outro under a chapter titled ED is an ending', () {
      expect(
        skipLabelFor(seg(MediaSegmentKind.outro, 1300, 1390), [
          ch('Part B', 700, 1300),
          ch('Ending - Artist', 1300, 1390),
        ]),
        SkipLabel.ending,
      );
    });

    test('plain titles stay intro and credits', () {
      expect(
        skipLabelFor(seg(MediaSegmentKind.intro, 0, 40), [
          ch('Opening credits', 0, 40),
        ]),
        SkipLabel.intro,
      );
      expect(
        skipLabelFor(seg(MediaSegmentKind.outro, 0, 40), [
          ch('Ending credits', 0, 40),
        ]),
        SkipLabel.credits,
      );
      expect(
        skipLabelFor(seg(MediaSegmentKind.intro, 0, 40), const []),
        SkipLabel.intro,
      );
    });

    test('other kinds keep their own label', () {
      expect(
        skipLabelFor(seg(MediaSegmentKind.recap, 0, 40), const []),
        SkipLabel.recap,
      );
    });
  });
}

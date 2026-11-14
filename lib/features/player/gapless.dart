// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import '../settings/player_settings.dart';
import 'playback_state.dart';

/// The queue as it will stand once the next song has started by itself, or
/// null when nothing should be handed to mpv ahead of time.
///
/// mpv's `gapless-audio` only joins files that are both in *its* playlist; the
/// app's queue is not, so the next song is resolved early and appended there
/// ([PlaybackController] does the appending). This is the rule for when.
///
/// - Music only. A video queue waits on "Auto-play next episode" and on the
///   end-of-episode prompt, neither of which a pre-loaded file would honour.
/// - Not with gapless off: the user asked for a reinitialised decoder between
///   files, and getting it from a fresh `open` is exactly that.
/// - Not on repeat-one, where mpv loops the file itself and never reaches the
///   next.
/// - Off the end of the queue only on repeat-all, back to its top.
/// - Not while [stopAfterCurrent] is set: the song after this one must not
///   start at all.
PlaybackQueue? gaplessNext(
  PlaybackQueue queue, {
  required LoopMode loop,
  required GaplessAudio gapless,
  bool stopAfterCurrent = false,
}) {
  if (!queue.isMusic || gapless == GaplessAudio.off) return null;
  if (loop == LoopMode.one || stopAfterCurrent) return null;

  if (queue.hasNext) return queue.stepTo(queue.index + 1);
  if (loop == LoopMode.all && queue.hasSiblings) return queue.stepTo(0);
  return null;
}

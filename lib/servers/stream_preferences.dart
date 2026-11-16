// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../downloads/download_settings.dart';

/// A quality the user can ask a server for.
///
/// A ceiling, not a demand: the server hands the file over untouched when it
/// already fits under the cap, and only re-encodes when it does not. So
/// [original] is not "best quality" — it is "never re-encode", which on a LAN
/// is both the fastest and the best-looking option, and over a phone
/// connection is the one that stalls.
@immutable
class StreamQuality {
  const StreamQuality({
    required this.id,
    required this.label,
    this.maxBitrate,
    this.maxHeight,
  });

  /// Stored, so the ladder can be reordered without changing what a user
  /// picked last week.
  final String id;

  final String label;

  /// Bits per second. Null means no cap at all.
  final int? maxBitrate;

  /// Null leaves the resolution alone; a transcode is then only about
  /// bitrate.
  final int? maxHeight;

  bool get isOriginal => maxBitrate == null && maxHeight == null;
}

/// The ladder offered in the picker.
///
/// Coarse on purpose. Every step here is a visibly different picture on a
/// phone; a list with 4.0 and 3.5 Mbps in it asks the user a question they
/// cannot answer.
const streamQualities = <StreamQuality>[
  StreamQuality(id: 'original', label: 'Original'),
  StreamQuality(
    id: 'uhd',
    label: '4K · 80 Mbps',
    maxBitrate: 80000000,
    maxHeight: 2160,
  ),
  StreamQuality(
    id: 'fhd20',
    label: '1080p · 20 Mbps',
    maxBitrate: 20000000,
    maxHeight: 1080,
  ),
  StreamQuality(
    id: 'fhd10',
    label: '1080p · 10 Mbps',
    maxBitrate: 10000000,
    maxHeight: 1080,
  ),
  StreamQuality(
    id: 'hd4',
    label: '720p · 4 Mbps',
    maxBitrate: 4000000,
    maxHeight: 720,
  ),
  StreamQuality(
    id: 'sd2',
    label: '480p · 2 Mbps',
    maxBitrate: 2000000,
    maxHeight: 480,
  ),
  StreamQuality(
    id: 'low',
    label: '360p · 1 Mbps',
    maxBitrate: 1000000,
    maxHeight: 360,
  ),
];

/// The rungs of [streamQualities] worth offering for one file.
///
/// A cap only does anything when it lowers something. A rung taller than the
/// file is hidden outright — "4K" over a 1080p file promises a picture that
/// is not there. Of the rest, a rung stays when it lowers the resolution
/// *or* the bitrate: a 1080p, 2 Mbps file keeps "720p · 4 Mbps", since the
/// server scales it down to 720p (useful on a weak decoder or a small
/// screen) and will not spend more bits than the file has; it loses
/// "1080p · 10 Mbps", which would change nothing. Original always stays, and
/// so does [selected], so the sheet still shows what is in force. Whatever
/// the server did not report is not compared.
///
/// The height is taken as the larger of the real height and what the width
/// implies at 16:9, so a 1920×800 scope rip counts as the 1080p it is.
List<StreamQuality> qualitiesFor({
  int? sourceBitrate,
  int? sourceWidth,
  int? sourceHeight,
  String? selected,
}) {
  final height = _effectiveHeight(sourceWidth, sourceHeight);

  bool useful(StreamQuality q) {
    if (q.isOriginal || q.id == selected) return true;
    final cap = q.maxHeight;
    final bitrate = q.maxBitrate;
    if (height != null && cap != null && cap > height) return false;

    final lowersHeight = height == null || cap == null || cap < height;
    final lowersBitrate =
        sourceBitrate == null || bitrate == null || bitrate < sourceBitrate;
    return lowersHeight || lowersBitrate;
  }

  return <StreamQuality>[
    for (final StreamQuality q in streamQualities)
      if (useful(q)) q,
  ];
}

/// The larger of the real height and what the width implies at 16:9.
int? _effectiveHeight(int? width, int? height) {
  final fromWidth = width == null ? null : (width * 9 / 16).round();
  return switch ((height, fromWidth)) {
    (final int h, final int w) => h > w ? h : w,
    (final int h, null) => h,
    (null, final int w) => w,
    _ => null,
  };
}

/// What the original file is — "1080p · 2.1 Mbps" — for the Original rung,
/// which otherwise says nothing about what "original" means for this file.
///
/// The height is snapped to the usual name when it is within 10% of it, so
/// a 1916-wide encode reads as 1080p rather than 1078p. Null when the
/// server reported neither size nor bitrate.
String? sourceQualityLabel({int? width, int? height, int? bitrate}) {
  final h = _effectiveHeight(width, height);
  String? resolution;
  if (h != null && h > 0) {
    const tiers = <int>[4320, 2160, 1440, 1080, 720, 576, 480, 360, 240];
    final tier = tiers.where((t) => h >= t * 0.9).firstOrNull;
    resolution = switch (tier ?? h) {
      4320 => '8K',
      2160 => '4K',
      final int t => '${t}p',
    };
  }
  final rate = bitrate == null || bitrate <= 0
      ? null
      : '${(bitrate / 1000000).toStringAsFixed(1)} Mbps';
  final parts = <String>[?resolution, ?rate];
  return parts.isEmpty ? null : parts.join(' · ');
}

StreamQuality qualityById(String? id) {
  for (final StreamQuality q in streamQualities) {
    if (q.id == id) return q;
  }
  return streamQualities.first;
}

/// The quality cap chosen for each kind of network.
@immutable
class StreamQualityDefaults {
  const StreamQualityDefaults({
    this.wifi = const StreamQuality(id: 'original', label: 'Original'),
    this.cellular = const StreamQuality(id: 'original', label: 'Original'),
  });

  /// Wi-Fi, Ethernet, and anything the platform cannot name.
  final StreamQuality wifi;

  /// Mobile data, where every megabit is paid for.
  final StreamQuality cellular;

  StreamQuality forNetwork({required bool metered}) =>
      metered ? cellular : wifi;

  StreamQualityDefaults copyWith({
    StreamQuality? wifi,
    StreamQuality? cellular,
  }) =>
      StreamQualityDefaults(
        wifi: wifi ?? this.wifi,
        cellular: cellular ?? this.cellular,
      );
}

/// The two caps, persisted. Original for both out of the box: the common case
/// is a server on the same network, where re-encoding costs picture quality
/// and CPU and buys nothing — and on mobile data the user is better asked
/// once, in Player settings, than surprised by a soft picture.
class StreamQualityDefaultsController
    extends Notifier<StreamQualityDefaults> {
  /// The Wi-Fi key is the one the single setting used to live under, so a
  /// choice made before there were two carries over as the Wi-Fi one.
  static const _wifiKey = 'stream_quality_v1';
  static const _cellularKey = 'stream_quality_cellular_v1';

  @override
  StreamQualityDefaults build() {
    Future<void>.microtask(_restore);
    return const StreamQualityDefaults();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wifi = prefs.getString(_wifiKey);
      final cellular = prefs.getString(_cellularKey);
      state = state.copyWith(
        wifi: wifi == null ? null : qualityById(wifi),
        cellular: cellular == null ? null : qualityById(cellular),
      );
    } catch (e) {
      debugPrint('Unreadable stream quality, using the default: $e');
    }
  }

  Future<void> setWifi(StreamQuality quality) async {
    state = state.copyWith(wifi: quality);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_wifiKey, quality.id);
  }

  Future<void> setCellular(StreamQuality quality) async {
    state = state.copyWith(cellular: quality);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cellularKey, quality.id);
  }

}

/// A quality picked in the player for what is being watched, or null for
/// Auto — the cap Player settings set for the network the device is on.
///
/// Memory only, and dropped when the player closes: the settings are the
/// standing answer, and a one-off choice for a bad connection must not
/// quietly become it.
class StreamQualityOverrideController extends Notifier<StreamQuality?> {
  @override
  StreamQuality? build() => null;

  void set(StreamQuality? quality) => state = quality;

  void clear() => state = null;
}

final streamQualityOverrideProvider =
    NotifierProvider<StreamQualityOverrideController, StreamQuality?>(
      StreamQualityOverrideController.new,
    );

/// Auto's cap: the most a stream may be on the network the device is on now.
final streamQualityCapProvider = Provider<StreamQuality>((ref) {
  final defaults = ref.watch(streamQualityDefaultsProvider);
  return defaults.forNetwork(metered: ref.watch(streamOnMeteredProvider));
});

final streamQualityDefaultsProvider =
    NotifierProvider<StreamQualityDefaultsController, StreamQualityDefaults>(
      StreamQualityDefaultsController.new,
    );

/// Whether the device is on mobile data. False while the platform has not
/// said, and wherever it cannot: the Wi-Fi cap is the safe guess for a
/// desktop or a television.
final streamOnMeteredProvider = Provider<bool>(
  (ref) => ref.watch(downloadNetworkProvider).value == DownloadNetwork.metered,
);

/// The quality cap every server request is made under: what the player was
/// told for this session, else Auto's cap for the network. Under a cap the
/// server still decides — it plays the file as it is when it fits, and
/// transcodes down to the cap when it does not.
final streamQualityProvider = Provider<StreamQuality>(
  (ref) =>
      ref.watch(streamQualityOverrideProvider) ??
      ref.watch(streamQualityCapProvider),
);

/// An audio and subtitle choice made *before* playback starts.
///
/// Carries the item it was made for. A choice is a set of stream indexes, and
/// those numbers mean something entirely different in the next file — so
/// rather than trusting whoever clears it, the resolve checks that the id
/// still matches and ignores the choice if it does not.
@immutable
class TrackChoice {
  const TrackChoice({
    required this.itemId,
    this.audioStreamIndex,
    this.subtitleStreamIndex,
    this.mediaSourceId,
  });

  final String itemId;
  final int? audioStreamIndex;

  /// Null means "no subtitles", which the server distinguishes from "decide
  /// for me" — the latter is simply not sending the parameter.
  final int? subtitleStreamIndex;

  final String? mediaSourceId;
}

/// Set by the detail screen just before it opens the player, read once by the
/// resolve, and never persisted.
class TrackChoiceController extends Notifier<TrackChoice?> {
  @override
  TrackChoice? build() => null;

  void set(TrackChoice? choice) => state = choice;

  /// The choice for [itemId], or null when the last one was made for
  /// something else.
  TrackChoice? forItem(String itemId) {
    final current = state;
    return current != null && current.itemId == itemId ? current : null;
  }
}

final trackChoiceProvider =
    NotifierProvider<TrackChoiceController, TrackChoice?>(
      TrackChoiceController.new,
    );

/// Everything a resolve needs to know about how the user wants this played.
///
/// Handed to `JellyfinMediaSource` as a callback rather than a value: the
/// source is built once and resolves many times, and reading the preference
/// at resolve time is what lets a quality change take effect on the next
/// file without rebuilding the source map.
@immutable
class StreamPreferences {
  const StreamPreferences({
    this.quality = const StreamQuality(id: 'original', label: 'Original'),
    this.trackChoice,
    this.burnInImageSubtitles = true,
  });

  final StreamQuality quality;
  final TrackChoice? trackChoice;

  /// See [burnInSubtitlesProvider].
  final bool burnInImageSubtitles;
}

/// Whether a transcode may burn an image-based subtitle into the picture.
///
/// Only image subtitles are in question: text ones (SRT, WebVTT, ASS) are
/// asked for beside the stream and drawn by libmpv, transcode or not. PGS and
/// VobSub cannot travel that way, so a transcode either paints them into the
/// video — on the server's CPU, re-encoding the whole picture — or plays
/// without them. Off is the second answer.
class BurnInSubtitlesController extends Notifier<bool> {
  static const _key = 'burn_in_image_subtitles_v1';

  final Completer<void> _restored = Completer<void>();

  /// Completes once the stored value has been read, so the account sync
  /// (`account_prefs.dart`) does not take the restore for a choice.
  Future<void> get ready => _restored.future;

  @override
  bool build() {
    Future<void>.microtask(() async {
      try {
        await _restore();
      } finally {
        if (!_restored.isCompleted) _restored.complete();
      }
    });
    return true;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_key);
      if (saved != null) state = saved;
    } catch (e) {
      debugPrint('Unreadable burn-in preference, using the default: $e');
    }
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}

final burnInSubtitlesProvider =
    NotifierProvider<BurnInSubtitlesController, bool>(
  BurnInSubtitlesController.new,
);

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

/// Keeps the player settings the server can hold on the server.
///
/// Preferred language, smart subtitles and auto-play next are fields of the
/// user's Jellyfin configuration ([ServerPlaybackPreferences]), so they follow
/// the account from device to device. Everything else in [PlayerSettings] is
/// about this device — its decoder, its speakers, its screen — and stays in
/// `shared_preferences`.
///
/// The local copy of the three stays too, as a cache: it is what plays with
/// no server open, and a downloaded film offline.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../servers/media_library_source.dart';
import '../servers/server_library.dart';
import 'player_settings.dart';

/// The server's share of [settings].
ServerPlaybackPreferences serverPartOf(PlayerSettings settings) =>
    ServerPlaybackPreferences(
      language: settings.preferredLanguage,
      smartSubtitles: settings.smartSubtitles,
      autoPlayNext: settings.autoPlayNext,
    );

/// [settings] with the server's choices laid over it.
PlayerSettings withServerPart(
  PlayerSettings settings,
  ServerPlaybackPreferences server,
) =>
    settings.copyWith(
      preferredLanguage: server.language,
      clearPreferredLanguage: server.language == null,
      smartSubtitles: server.smartSubtitles,
      autoPlayNext: server.autoPlayNext,
    );

/// Watched once, from the app's root, for as long as the app runs.
final serverPlayerPrefsSyncProvider = Provider<void>((ref) {
  final sync = _PlayerPrefsSync(ref);

  ref.listen<PlayerSettings>(
    playerSettingsProvider,
    (previous, next) => sync.localChanged(next),
  );
  ref.listen<MediaLibrarySource?>(
    connectedServerProvider,
    (previous, next) {
      if (next != null && !identical(previous, next)) sync.connected(next);
    },
    fireImmediately: true,
  );
});

class _PlayerPrefsSync {
  _PlayerPrefsSync(this.ref) {
    ref.read(playerSettingsProvider.notifier).ready.then((_) => _live = true);
  }

  final Ref ref;

  /// False until the stored settings are in: their arrival is a restore, not
  /// a choice, and sending it would overwrite what another device chose.
  bool _live = false;

  /// Set while a choice made here has not reached a server yet — changed with
  /// no server open, or the write failed. The next server opened is then told
  /// rather than asked, so the choice is not lost to the server's older one.
  static const _pendingKey = 'player_server_prefs_pending_v1';

  /// What the server was last known to hold. A settings change equal to it
  /// is the server's own answer arriving, not something to send back.
  ServerPlaybackPreferences? _server;

  /// Bumped on every change made here, so a read that started before one
  /// does not land on top of it.
  int _generation = 0;

  Future<void> connected(MediaLibrarySource source) async {
    _server = null;
    final generation = _generation;
    try {
      await ref.read(playerSettingsProvider.notifier).ready;
      final prefs = await SharedPreferences.getInstance();

      if (prefs.getBool(_pendingKey) ?? false) {
        await _push(source, serverPartOf(ref.read(playerSettingsProvider)));
        return;
      }

      final server = await source.playbackPreferences();
      if (server == null || generation != _generation) return;
      if (!identical(ref.read(connectedServerProvider), source)) return;

      _server = server;
      final current = ref.read(playerSettingsProvider);
      if (serverPartOf(current) == server) return;
      await ref
          .read(playerSettingsProvider.notifier)
          .update(withServerPart(current, server));
    } catch (e) {
      // The local choices keep playing; the next connection tries again.
      debugPrint('Playback preferences not read from the server: $e');
    }
  }

  Future<void> localChanged(PlayerSettings next) async {
    if (!_live) return;
    final part = serverPartOf(next);
    if (part == _server) return;

    _generation++;
    final source = ref.read(connectedServerProvider);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_pendingKey, true);
      if (source != null) await _push(source, part);
    } catch (e) {
      debugPrint('Playback preferences not saved to the server: $e');
    }
  }

  Future<void> _push(
    MediaLibrarySource source,
    ServerPlaybackPreferences part,
  ) async {
    await source.setPlaybackPreferences(part);
    _server = part;
    // Only if nothing newer was chosen while this one was on its way.
    if (serverPartOf(ref.read(playerSettingsProvider)) == part) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_pendingKey, false);
    }
  }
}

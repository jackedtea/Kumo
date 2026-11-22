// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

/// Keeps the app's own account-wide choices on the server.
///
/// Jellyfin has no field for a skip length, a segment action or what a
/// library card shows, but it keeps a free map of strings per user and per
/// client (`DisplayPreferences/usersettings`, `CustomPrefs` — where its own
/// web client keeps the same kind of thing). Each choice here is one key in
/// that map, written as a string by the binding that owns it.
///
/// The local copy of each stays, as a cache: it is what the app shows with
/// no server open, and the starting point when a server has nothing yet.
///
/// Three rules, the same as `server_player_prefs.dart`:
///
/// - Opening a server **asks** it, and lays what it holds over the local
///   value. A key the server does not have yet is **told** instead.
/// - A change made here is sent at once. With no server open, or when the
///   write fails, the key is marked pending and the next server opened is
///   told rather than asked, so the choice is not lost to an older one.
/// - A local value's first arrival from disk is a restore, not a choice, and
///   is never sent.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:shared_preferences/shared_preferences.dart';

import '../../servers/media_library_source.dart';
import '../../servers/stream_preferences.dart';
import '../home/favorites_page.dart';
import '../libraries/last_library.dart';
import '../player/remembered_tracks.dart';
import '../search/search_history.dart';
import '../servers/library_view_settings.dart';
import '../servers/server_library.dart';
import 'player_settings.dart';

/// One choice kept under one key of the server's map.
@immutable
class AccountPrefBinding {
  const AccountPrefBinding({
    required this.key,
    required this.watch,
    required this.ready,
    required this.current,
    required this.apply,
  });

  /// The key in the server's map. Never renamed: another device reads it.
  final String key;

  /// What changes when the choice does.
  final ProviderListenable<Object?> watch;

  /// Completes once the local value has been read from disk.
  final Future<void> Function(Ref ref) ready;

  /// The choice as a string, or null while there is nothing to say yet.
  final String? Function(Ref ref, MediaLibrarySource? source) current;

  /// Lays a value from the server over the local one.
  final Future<void> Function(Ref ref, MediaLibrarySource source, String value)
      apply;
}

/// The player choices the server has no field for. Language, smart subtitles
/// and auto-play next have fields, and go through `server_player_prefs.dart`.
const _playerKeys = <String>[
  'skipBackSeconds',
  'skipForwardSeconds',
  'segmentActions',
  'hideIntroBesideOpening',
  'gapless',
  'replayGain',
];

String encodePlayerPrefs(PlayerSettings settings) {
  final all = settings.toJson();
  return jsonEncode(<String, dynamic>{
    for (final String k in _playerKeys) k: all[k],
  });
}

PlayerSettings decodePlayerPrefs(PlayerSettings settings, String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) return settings;
  return PlayerSettings.fromJson(<String, dynamic>{
    ...settings.toJson(),
    for (final String k in _playerKeys)
      if (decoded.containsKey(k)) k: decoded[k],
  });
}

String encodeCardInfo(LibraryCardInfo info) => jsonEncode(<String, bool>{
  'year': info.year,
  'count': info.count,
  'status': info.status,
});

LibraryCardInfo decodeCardInfo(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return const LibraryCardInfo();
  return LibraryCardInfo(
    year: decoded['year'] as bool? ?? true,
    count: decoded['count'] as bool? ?? true,
    status: decoded['status'] as bool? ?? true,
  );
}

/// Every choice kept on the account, by key.
final accountPrefBindings = <AccountPrefBinding>[
  AccountPrefBinding(
    key: 'player',
    watch: playerSettingsProvider,
    ready: (ref) => ref.read(playerSettingsProvider.notifier).ready,
    current: (ref, _) => encodePlayerPrefs(ref.read(playerSettingsProvider)),
    apply: (ref, _, value) async {
      final notifier = ref.read(playerSettingsProvider.notifier);
      await notifier.update(
        decodePlayerPrefs(ref.read(playerSettingsProvider), value),
      );
    },
  ),
  AccountPrefBinding(
    key: 'burnInImageSubtitles',
    watch: burnInSubtitlesProvider,
    ready: (ref) => ref.read(burnInSubtitlesProvider.notifier).ready,
    current: (ref, _) => '${ref.read(burnInSubtitlesProvider)}',
    apply: (ref, _, value) =>
        ref.read(burnInSubtitlesProvider.notifier).set(value == 'true'),
  ),
  AccountPrefBinding(
    key: 'homeShowFavourites',
    watch: homeShowFavouritesProvider,
    ready: (ref) => ref.read(homeShowFavouritesProvider.future),
    current: (ref, _) => switch (ref.read(homeShowFavouritesProvider).value) {
      final bool v => '$v',
      null => null,
    },
    apply: (ref, _, value) =>
        ref.read(homeShowFavouritesProvider.notifier).set(value == 'true'),
  ),
  AccountPrefBinding(
    key: 'libraryCardInfo',
    watch: libraryCardInfoProvider,
    ready: (ref) => ref.read(libraryCardInfoProvider.notifier).ready,
    current: (ref, _) => encodeCardInfo(ref.read(libraryCardInfoProvider)),
    apply: (ref, _, value) =>
        ref.read(libraryCardInfoProvider.notifier).set(decodeCardInfo(value)),
  ),
  // The map is per profile on the device; on the server it is already this
  // server's, so only this profile's entry travels.
  AccountPrefBinding(
    key: 'lastLibrary',
    watch: lastLibraryProvider,
    ready: (ref) => ref.read(lastLibraryProvider.future),
    current: (ref, source) => source == null
        ? null
        : ref.read(lastLibraryProvider).value?[source.profile.id],
    apply: (ref, source, value) =>
        ref.read(lastLibraryProvider.notifier).remember(source.profile.id, value),
  ),
  AccountPrefBinding(
    key: 'searchHistory',
    watch: searchHistoryProvider,
    ready: (ref) => ref.read(searchHistoryProvider.future),
    current: (ref, _) => switch (ref.read(searchHistoryProvider).value) {
      final List<String> v => jsonEncode(v),
      null => null,
    },
    apply: (ref, _, value) {
      final decoded = jsonDecode(value);
      return ref
          .read(searchHistoryProvider.notifier)
          .replace(decoded is List ? decoded.whereType<String>().toList() : []);
    },
  ),
  AccountPrefBinding(
    key: 'rememberedTracks',
    watch: rememberedTracksProvider,
    ready: (ref) => ref.read(rememberedTracksProvider.future),
    current: (ref, _) => switch (ref.read(rememberedTracksProvider).value) {
      final Map<String, RememberedTracks> v => encodeRememberedTracks(v),
      null => null,
    },
    apply: (ref, _, value) => ref
        .read(rememberedTracksProvider.notifier)
        .replaceAll(decodeRememberedTracks(value)),
  ),
];

/// Watched once, from the app's root, for as long as the app runs.
final accountPrefsSyncProvider = Provider<void>((ref) {
  final sync = _AccountPrefsSync(ref, accountPrefBindings);

  for (final AccountPrefBinding b in accountPrefBindings) {
    ref.listen<Object?>(b.watch, (_, _) => sync.localChanged(b));
  }
  ref.listen<MediaLibrarySource?>(
    connectedServerProvider,
    (previous, next) {
      if (next != null && !identical(previous, next)) sync.connected(next);
    },
    fireImmediately: true,
  );
});

class _AccountPrefsSync {
  _AccountPrefsSync(this.ref, this.bindings) {
    for (final AccountPrefBinding b in bindings) {
      b.ready(ref).then((_) {
        _seen[b.key] = b.current(ref, _source);
        _live.add(b.key);
      }, onError: (_) {});
    }
  }

  final Ref ref;
  final List<AccountPrefBinding> bindings;

  static const _pendingKey = 'account_prefs_pending_v1';

  /// Keys whose local value has been read from disk.
  final Set<String> _live = <String>{};

  /// Each key's value as last seen here. A provider that changes without
  /// this key's part changing — the player settings carry device-only fields
  /// too — is not a change to send.
  final Map<String, String?> _seen = <String, String?>{};

  /// What the open server was last known to hold, per key. A change equal to
  /// it is the server's own value arriving, not something to send back.
  final Map<String, String> _server = <String, String>{};

  /// Keys changed here and not yet sent.
  final Set<String> _dirty = <String>{};

  bool _flushing = false;

  /// Keys whose server value is being laid over the local one right now:
  /// the change that makes is the server's, not the user's.
  final Set<String> _applying = <String>{};

  MediaLibrarySource? get _source => ref.read(connectedServerProvider);

  Future<void> connected(MediaLibrarySource source) async {
    _server.clear();
    try {
      await Future.wait(
        bindings.map((b) => b.ready(ref).catchError((Object _) {})),
      );
      final prefs = await SharedPreferences.getInstance();
      final pending = (prefs.getStringList(_pendingKey) ?? const <String>[])
          .toSet();

      final remote = await source.accountPrefs();
      if (remote == null || !identical(_source, source)) return;

      for (final AccountPrefBinding b in bindings) {
        final local = b.current(ref, source);
        final held = remote[b.key];

        if (pending.contains(b.key) || held == null) {
          if (local != null) _dirty.add(b.key);
          continue;
        }
        // Changed here while the server was being asked: that one stands.
        if (_dirty.contains(b.key)) continue;

        _server[b.key] = held;
        if (held != local) {
          _applying.add(b.key);
          try {
            await b.apply(ref, source, held);
            // What the server holds, as this build writes it — a value from
            // an older build may lack a field, and must not read as a change.
            _server[b.key] = b.current(ref, source) ?? held;
            _seen[b.key] = _server[b.key];
          } catch (e) {
            debugPrint('Unreadable server value for ${b.key}: $e');
          } finally {
            _applying.remove(b.key);
          }
        }
      }
      await _flush();
    } catch (e) {
      // The local choices stand; the next connection tries again.
      debugPrint('Account preferences not read from the server: $e');
    }
  }

  Future<void> localChanged(AccountPrefBinding b) async {
    if (!_live.contains(b.key) || _applying.contains(b.key)) return;
    final value = b.current(ref, _source);
    if (value == null || value == _seen[b.key]) return;
    _seen[b.key] = value;
    if (value == _server[b.key]) return;

    _dirty.add(b.key);
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = (prefs.getStringList(_pendingKey) ?? const <String>[])
          .toSet();
      if (pending.add(b.key)) {
        await prefs.setStringList(_pendingKey, pending.toList());
      }
    } catch (e) {
      debugPrint('Pending account preference not noted: $e');
    }
    await _flush();
  }

  /// Sends what is dirty, one write at a time; changes made while a write is
  /// on its way go in the next one.
  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_dirty.isNotEmpty) {
        final source = _source;
        if (source == null) return;

        final changes = <String, String>{};
        for (final AccountPrefBinding b in bindings) {
          if (!_dirty.contains(b.key)) continue;
          final value = b.current(ref, source);
          if (value != null) changes[b.key] = value;
        }
        _dirty.clear();
        if (changes.isEmpty) return;

        try {
          await source.setAccountPrefs(changes);
        } catch (e) {
          // Still pending on disk; the next server opened is told.
          debugPrint('Account preferences not saved to the server: $e');
          return;
        }
        _server.addAll(changes);

        final prefs = await SharedPreferences.getInstance();
        final pending = (prefs.getStringList(_pendingKey) ?? const <String>[])
            .toSet()
          ..removeWhere((k) => changes.containsKey(k) && !_dirty.contains(k));
        await prefs.setStringList(_pendingKey, pending.toList());
      }
    } finally {
      _flushing = false;
    }
  }
}

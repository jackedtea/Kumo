// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../servers/books.dart';
import '../../servers/media_library_source.dart';

/// Sends where the reader is to the server, without a request per page.
///
/// A page turn starts a five-second wait; another turn restarts it, so a
/// reader flicking through a chapter costs one write. [flush] sends at once
/// — leaving the reader does, so the last page is never lost to the wait.
///
/// The server is the only store (memory: prefer server storage). When it
/// cannot be reached the position waits in [PendingBookPositions] and goes
/// out the next time this book, or any book on that server, is opened.
class BookProgressSaver {
  BookProgressSaver({
    required this.source,
    required this.itemId,
    String? profileId,
    this.delay = const Duration(seconds: 5),
    PendingBookPositions? pending,
  }) : profileId = profileId ?? source!.profile.id,
       _pending = pending ?? PendingBookPositions();

  /// Null for a downloaded book read with its server not signed in: every
  /// position then waits in [PendingBookPositions].
  final MediaLibrarySource? source;
  final String profileId;
  final String itemId;
  final Duration delay;
  final PendingBookPositions _pending;

  Timer? _timer;
  BookPosition? _unsent;
  bool _finished = false;
  BookPosition? _lastSent;

  /// The reader moved to [position].
  void update(BookPosition position) {
    if (position == _lastSent && !_finished) return;
    _unsent = position;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// The reader reached the end, or the user said the book is read.
  Future<void> finish(BookPosition position) {
    _finished = true;
    _unsent = position;
    return flush();
  }

  /// Sends what has not been sent. Never throws.
  Future<void> flush() async {
    _timer?.cancel();
    final position = _unsent;
    if (position == null) return;
    _unsent = null;
    final finished = _finished ? true : null;
    final server = source;
    try {
      if (server == null) throw StateError('no server signed in');
      await server.setBookPosition(itemId, position, finished: finished);
      _lastSent = position;
      await _pending.remove(profileId, itemId);
    } on Object catch (e) {
      debugPrint('Book position not sent, kept for later: $e');
      await _pending.put(
        profileId,
        itemId,
        PendingBookPosition(ticks: position.ticks, finished: _finished),
      );
    }
  }

  /// Stops the wait. What has not been sent stays unsent: call [flush] (or
  /// [finish]) first.
  void dispose() => _timer?.cancel();
}

@immutable
class PendingBookPosition {
  const PendingBookPosition({required this.ticks, this.finished = false});

  final int ticks;
  final bool finished;

  Map<String, Object> toJson() => <String, Object>{
    'ticks': ticks,
    'finished': finished,
  };

  static PendingBookPosition? fromJson(Object? json) {
    if (json is! Map) return null;
    final ticks = json['ticks'];
    if (ticks is! int) return null;
    return PendingBookPosition(
      ticks: ticks,
      finished: json['finished'] == true,
    );
  }
}

/// Positions the server has not heard yet, newest per book, per profile.
///
/// The one local copy of reading progress, and only until it can be sent:
/// a book read on a plane must not open on page one at home.
class PendingBookPositions {
  static const _key = 'books_pending_positions_v1';

  Future<Map<String, Map<String, PendingBookPosition>>> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return <String, Map<String, PendingBookPosition>>{};
      final json = jsonDecode(raw);
      if (json is! Map) return <String, Map<String, PendingBookPosition>>{};
      return <String, Map<String, PendingBookPosition>>{
        for (final MapEntry<dynamic, dynamic> profile in json.entries)
          if (profile.key is String && profile.value is Map)
            profile.key as String: <String, PendingBookPosition>{
              for (final MapEntry<dynamic, dynamic> item
                  in (profile.value as Map).entries)
                if (item.key is String &&
                    PendingBookPosition.fromJson(item.value) != null)
                  item.key as String: PendingBookPosition.fromJson(item.value)!,
            },
      };
    } on Object catch (e) {
      debugPrint('Could not read the pending book positions: $e');
      return <String, Map<String, PendingBookPosition>>{};
    }
  }

  Future<void> _write(Map<String, Map<String, PendingBookPosition>> all) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      all.removeWhere((_, items) => items.isEmpty);
      if (all.isEmpty) {
        await prefs.remove(_key);
        return;
      }
      await prefs.setString(
        _key,
        jsonEncode(<String, Object>{
          for (final MapEntry<String, Map<String, PendingBookPosition>> p
              in all.entries)
            p.key: <String, Object>{
              for (final MapEntry<String, PendingBookPosition> i
                  in p.value.entries)
                i.key: i.value.toJson(),
            },
        }),
      );
    } on Object catch (e) {
      debugPrint('Could not save a pending book position: $e');
    }
  }

  Future<void> put(
    String profileId,
    String itemId,
    PendingBookPosition position,
  ) async {
    final all = await _read();
    (all[profileId] ??= <String, PendingBookPosition>{})[itemId] = position;
    await _write(all);
  }

  Future<void> remove(String profileId, String itemId) async {
    final all = await _read();
    if (all[profileId]?.remove(itemId) == null) return;
    await _write(all);
  }

  Future<PendingBookPosition?> get(String profileId, String itemId) async =>
      (await _read())[profileId]?[itemId];

  /// Sends every position waiting for [source]'s server. What still fails
  /// stays. Never throws.
  Future<void> sendAll(MediaLibrarySource source) async {
    final all = await _read();
    final mine = all[source.profile.id];
    if (mine == null || mine.isEmpty) return;
    for (final MapEntry<String, PendingBookPosition> e
        in mine.entries.toList()) {
      try {
        await source.setBookPosition(
          e.key,
          _RawTicks(e.value.ticks),
          finished: e.value.finished ? true : null,
        );
        mine.remove(e.key);
      } on Object catch (error) {
        debugPrint('Pending book position still not sent: $error');
        break;
      }
    }
    await _write(all);
  }
}

/// A stored position sent back as it was kept, whatever the book's family.
class _RawTicks extends BookPosition {
  const _RawTicks(this._ticks) : super.page(0);

  final int _ticks;

  @override
  int get ticks => _ticks;
}

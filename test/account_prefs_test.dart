// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_library_source.dart';

import 'package:kumo/features/libraries/last_library.dart';
import 'package:kumo/features/search/search_history.dart';
import 'package:kumo/features/servers/library_view_settings.dart';
import 'package:kumo/features/servers/server_library.dart';
import 'package:kumo/features/settings/account_prefs.dart';
import 'package:kumo/features/settings/player_settings.dart';
import 'package:kumo/servers/jellyfin_dto.dart';
import 'package:kumo/servers/media_library_source.dart';
import 'package:kumo/servers/stream_preferences.dart';

/// A server holding this app's preference map, and every write made to it.
class _Server extends FakeLibrarySource {
  _Server([Map<String, String>? held]) : held = <String, String>{...?held};

  final Map<String, String> held;
  final List<Map<String, String>> writes = <Map<String, String>>[];

  @override
  Future<Map<String, String>?> accountPrefs() async => <String, String>{
    ...held,
  };

  @override
  Future<void> setAccountPrefs(Map<String, String> changes) async {
    writes.add(<String, String>{...changes});
    held.addAll(changes);
  }

  /// Every key written, across all writes.
  Set<String> get written => <String>{for (final w in writes) ...w.keys};
}

class _Connected extends Notifier<MediaLibrarySource?> {
  @override
  MediaLibrarySource? build() => null;

  void set(MediaLibrarySource? source) => state = source;
}

final _connected = NotifierProvider<_Connected, MediaLibrarySource?>(
  _Connected.new,
);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      connectedServerProvider.overrideWith((ref) => ref.watch(_connected)),
    ],
  );
  container.listen(accountPrefsSyncProvider, (_, _) {});
  return container;
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('library sort', () {
    test('a saved sort reads back as the sort it names', () {
      for (final ServerSort sort in ServerSort.values) {
        expect(serverSortFromSortBy(sortByFor(sort)), sort, reason: '$sort');
      }
      expect(serverSortFromSortBy('Nonsense'), isNull);
      expect(serverSortFromSortBy(null), isNull);
    });

    test('the natural direction comes back as no direction', () {
      expect(
        librarySortFromDisplayPrefs(<String, dynamic>{
          'SortBy': 'DateCreated',
          'SortOrder': 'Descending',
        }),
        (sort: ServerSort.dateAdded, order: null),
      );
      expect(
        librarySortFromDisplayPrefs(<String, dynamic>{
          'SortBy': 'DateCreated,SortName',
          'SortOrder': 'Ascending',
        }),
        (sort: ServerSort.dateAdded, order: SortOrder.ascending),
      );
    });
  });

  group('sync', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('a server opened lays its values over the local ones', () async {
      final container = _container();
      addTearDown(container.dispose);
      await _settle();

      final server = _Server(<String, String>{
        'player': jsonEncode(<String, dynamic>{'skipBackSeconds': 5}),
        'burnInImageSubtitles': 'false',
        'libraryCardInfo': jsonEncode(<String, bool>{
          'year': false,
          'count': true,
          'status': true,
        }),
        'lastLibrary': 'films',
        'searchHistory': jsonEncode(<String>['dune']),
      });
      container.read(_connected.notifier).set(server);
      await _settle();

      expect(
        container.read(playerSettingsProvider).skipBack,
        const Duration(seconds: 5),
      );
      expect(container.read(burnInSubtitlesProvider), isFalse);
      expect(container.read(libraryCardInfoProvider).year, isFalse);
      expect(
        container.read(lastLibraryProvider).value?[fakeServerProfile.id],
        'films',
      );
      expect(container.read(searchHistoryProvider).value, <String>['dune']);

      // What the server sent is not sent back; what it lacked is told.
      expect(server.written, isNot(contains('player')));
      expect(server.written, isNot(contains('burnInImageSubtitles')));
      expect(server.written, contains('homeShowFavourites'));
      expect(server.written, contains('rememberedTracks'));
    });

    test('a change made here goes to the server', () async {
      final container = _container();
      addTearDown(container.dispose);
      final server = _Server();
      container.read(_connected.notifier).set(server);
      await _settle();
      server.writes.clear();

      await container.read(burnInSubtitlesProvider.notifier).set(false);
      await _settle();

      expect(server.writes.single, <String, String>{
        'burnInImageSubtitles': 'false',
      });
    });

    test('a device-only player setting is not sent', () async {
      final container = _container();
      addTearDown(container.dispose);
      final server = _Server();
      container.read(_connected.notifier).set(server);
      await _settle();
      server.writes.clear();

      final notifier = container.read(playerSettingsProvider.notifier);
      await notifier.update(
        container.read(playerSettingsProvider).copyWith(swipeGestures: false),
      );
      await _settle();

      expect(server.writes, isEmpty);
    });

    test('a device-only change with no server open is not pending', () async {
      final container = _container();
      addTearDown(container.dispose);
      await _settle();

      final notifier = container.read(playerSettingsProvider.notifier);
      await notifier.update(
        container.read(playerSettingsProvider).copyWith(swipeGestures: false),
      );
      await _settle();

      final server = _Server(<String, String>{
        'player': jsonEncode(<String, dynamic>{'skipForwardSeconds': 15}),
      });
      container.read(_connected.notifier).set(server);
      await _settle();

      expect(
        container.read(playerSettingsProvider).skipForward,
        const Duration(seconds: 15),
      );
      expect(server.written, isNot(contains('player')));
    });

    test('a change with no server open wins over the next one', () async {
      final container = _container();
      addTearDown(container.dispose);
      await _settle();

      await container.read(searchHistoryProvider.notifier).add('arrival');
      await _settle();

      final server = _Server(<String, String>{
        'searchHistory': jsonEncode(<String>['older']),
      });
      container.read(_connected.notifier).set(server);
      await _settle();

      expect(container.read(searchHistoryProvider).value, <String>['arrival']);
      expect(server.held['searchHistory'], jsonEncode(<String>['arrival']));
    });
  });
}

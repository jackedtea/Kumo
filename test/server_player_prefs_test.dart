// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_library_source.dart';

import 'package:kumo/app/theme.dart';
import 'package:kumo/core/languages.dart';
import 'package:kumo/features/servers/server_library.dart';
import 'package:kumo/features/settings/player_settings.dart';
import 'package:kumo/features/settings/server_player_prefs.dart';
import 'package:kumo/features/settings/settings_widgets.dart';
import 'package:kumo/l10n/app_localizations.dart';
import 'package:kumo/servers/jellyfin_dto.dart';
import 'package:kumo/servers/media_library_source.dart';

class _Server extends FakeLibrarySource {
  _Server(this.held);

  ServerPlaybackPreferences held;
  final List<ServerPlaybackPreferences> writes = <ServerPlaybackPreferences>[];

  @override
  Future<ServerPlaybackPreferences?> playbackPreferences() async => held;

  @override
  Future<void> setPlaybackPreferences(ServerPlaybackPreferences p) async {
    writes.add(p);
    held = p;
  }
}

class _Connected extends Notifier<MediaLibrarySource?> {
  @override
  MediaLibrarySource? build() => null;

  void set(MediaLibrarySource? source) => state = source;
}

final _connected =
    NotifierProvider<_Connected, MediaLibrarySource?>(_Connected.new);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      connectedServerProvider.overrideWith((ref) => ref.watch(_connected)),
    ],
  );
  container.listen(serverPlayerPrefsSyncProvider, (_, _) {});
  return container;
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('user configuration', () {
    test('reads the audio language, then the subtitle one', () {
      expect(
        playbackPreferencesFromConfig(<String, dynamic>{
          'AudioLanguagePreference': 'vie',
          'SubtitleLanguagePreference': 'eng',
          'SubtitleMode': 'Smart',
          'EnableNextEpisodeAutoPlay': false,
        }),
        const ServerPlaybackPreferences(
          language: 'vi',
          smartSubtitles: true,
          autoPlayNext: false,
        ),
      );
      expect(
        playbackPreferencesFromConfig(<String, dynamic>{
          'AudioLanguagePreference': '',
          'SubtitleLanguagePreference': 'ger',
          'SubtitleMode': 'Always',
        }),
        const ServerPlaybackPreferences(language: 'de', smartSubtitles: false),
      );
    });

    test('writes the three fields and keeps every other one', () {
      final out = applyPlaybackPreferences(
        <String, dynamic>{
          'LatestItemsExcludes': <String>['v1'],
          'SubtitleMode': 'Smart',
        },
        const ServerPlaybackPreferences(
          language: 'fr',
          smartSubtitles: false,
          autoPlayNext: false,
        ),
      );

      expect(out['LatestItemsExcludes'], <String>['v1']);
      expect(out['AudioLanguagePreference'], 'fre');
      expect(out['SubtitleLanguagePreference'], 'fre');
      expect(out['SubtitleMode'], 'Default');
      expect(out['EnableNextEpisodeAutoPlay'], isFalse);
    });

    test('turning smart off keeps a mode chosen elsewhere', () {
      final out = applyPlaybackPreferences(
        <String, dynamic>{'SubtitleMode': 'None'},
        const ServerPlaybackPreferences(smartSubtitles: false),
      );
      expect(out['SubtitleMode'], 'None');
      expect(out['AudioLanguagePreference'], '');
    });

    test('every offered language round-trips through the server code', () {
      for (final LanguageOption option in languageOptions) {
        expect(
          canonicalLanguage(serverLanguageCode(option.code)),
          option.code,
          reason: option.label,
        );
      }
    });
  });

  group('sync', () {
    test('a server opened lays its choices over the local ones', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'player_settings_v1': jsonEncode(
          const PlayerSettings(preferredLanguage: 'en').toJson(),
        ),
      });
      final container = _container();
      addTearDown(container.dispose);
      container.read(playerSettingsProvider);
      await _settle();

      final server = _Server(
        const ServerPlaybackPreferences(language: 'vi', autoPlayNext: false),
      );
      container.read(_connected.notifier).set(server);
      await _settle();

      final settings = container.read(playerSettingsProvider);
      expect(settings.preferredLanguage, 'vi');
      expect(settings.autoPlayNext, isFalse);
      // The server's own answer is not sent back to it.
      expect(server.writes, isEmpty);
    });

    test('a change made here goes to the server', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = _container();
      addTearDown(container.dispose);
      final server = _Server(const ServerPlaybackPreferences());
      container.read(_connected.notifier).set(server);
      await _settle();

      final notifier = container.read(playerSettingsProvider.notifier);
      await notifier.update(
        container.read(playerSettingsProvider).copyWith(preferredLanguage: 'ja'),
      );
      await _settle();

      expect(server.writes.single.language, 'ja');

      // A device-only setting is nobody else's business.
      await notifier.update(
        container.read(playerSettingsProvider).copyWith(swipeGestures: false),
      );
      await _settle();
      expect(server.writes, hasLength(1));
    });

    test('a change with no server open is sent to the next one', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final container = _container();
      addTearDown(container.dispose);
      container.read(playerSettingsProvider);
      await _settle();

      await container.read(playerSettingsProvider.notifier).update(
            container
                .read(playerSettingsProvider)
                .copyWith(smartSubtitles: false),
          );
      await _settle();

      final server = _Server(const ServerPlaybackPreferences(language: 'en'));
      container.read(_connected.notifier).set(server);
      await _settle();

      expect(server.writes.single.smartSubtitles, isFalse);
      expect(container.read(playerSettingsProvider).smartSubtitles, isFalse);
    });
  });

  testWidgets('a marked row says it is saved on the server', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListView(
            children: <Widget>[
              SettingsSwitchRow(
                title: 'Kept',
                value: true,
                onChanged: (_) {},
                onServer: true,
              ),
              SettingsSwitchRow(
                title: 'Local',
                value: true,
                onChanged: (_) {},
              ),
              const ServerMarkLegend(),
            ],
          ),
        ),
      ),
    );

    // One on the marked row, one in the legend; none on the local row.
    expect(find.byType(ServerMark), findsNWidgets(2));
    expect(find.text('Saved on the server'), findsNothing);
    // Read out with the row's title, not as a separate stop.
    expect(
      find.bySemanticsLabel(RegExp('Kept.*Saved on the server', dotAll: true)),
      findsOneWidget,
    );
  });
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kumo/features/player/player_ui_state.dart';
import 'package:kumo/features/settings/player_settings.dart';
import 'package:kumo/servers/stream_preferences.dart';

ProviderContainer _container({required bool metered}) {
  final container = ProviderContainer(
    overrides: [streamOnMeteredProvider.overrideWithValue(metered)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('Auto caps per network', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('both start at Original, no limit', () {
      final c = _container(metered: false);
      expect(c.read(streamQualityProvider).isOriginal, isTrue);
      expect(c.read(streamQualityDefaultsProvider).cellular.isOriginal, isTrue);
    });

    test('mobile data uses the cellular cap, Wi-Fi its own', () async {
      final wifi = _container(metered: false);
      final cellular = _container(metered: true);
      for (final c in [wifi, cellular]) {
        final d = c.read(streamQualityDefaultsProvider.notifier);
        await d.setCellular(qualityById('hd4'));
        await d.setWifi(qualityById('fhd20'));
      }

      expect(wifi.read(streamQualityProvider).id, 'fhd20');
      expect(cellular.read(streamQualityProvider).id, 'hd4');
    });

    test('a quality picked in the player wins until cleared', () async {
      final c = _container(metered: true);
      await c.read(streamQualityDefaultsProvider.notifier)
          .setCellular(qualityById('hd4'));

      c.read(streamQualityOverrideProvider.notifier).set(qualityById('sd2'));
      expect(c.read(streamQualityProvider).id, 'sd2');
      // The cap itself is left alone by a one-off choice.
      expect(c.read(streamQualityCapProvider).id, 'hd4');

      c.read(streamQualityOverrideProvider.notifier).clear();
      expect(c.read(streamQualityProvider).id, 'hd4');
    });

    test('the single setting from before becomes the Wi-Fi cap', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'stream_quality_v1': 'fhd10',
      });
      final c = _container(metered: false);
      c.read(streamQualityDefaultsProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(c.read(streamQualityDefaultsProvider).wifi.id, 'fhd10');
      expect(c.read(streamQualityDefaultsProvider).cellular.isOriginal, isTrue);
    });
  });

  group('default rotation', () {
    test('follows the video unless chosen, and survives a round trip', () {
      expect(const PlayerSettings().defaultRotation, RotationMode.auto);

      final saved = const PlayerSettings(
        defaultRotation: RotationMode.landscape,
      ).toJson();
      expect(
        PlayerSettings.fromJson(saved).defaultRotation,
        RotationMode.landscape,
      );
      expect(
        PlayerSettings.fromJson(<String, dynamic>{'defaultRotation': 'x'})
            .defaultRotation,
        RotationMode.auto,
      );
    });
  });
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_library_source.dart';

import 'package:kumo/app/app.dart';
import 'package:kumo/app/router.dart';
import 'package:kumo/servers/jellyfin_dto.dart';
import 'package:kumo/servers/jellyfin_media_source.dart';
import 'package:kumo/servers/media_library_source.dart';
import 'package:kumo/servers/stream_preferences.dart';
import 'package:kumo/sources/media_source.dart';

/// Transcodes, burning in whatever subtitle it was asked for — or the one it
/// picked itself when asked for none.
class _TranscodingLibrary extends FakeLibrarySource {
  final List<int?> subtitleAsks = <int?>[];

  @override
  Future<ServerPlayback> playback(
    String itemId,
    PlaybackCapabilities caps, {
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    String? mediaSourceId,
  }) async {
    subtitleAsks.add(subtitleStreamIndex);
    final burns = subtitleStreamIndex != -1;
    return ServerPlayback(
      uri: Uri.parse(
        'https://media.home.lan/videos/$itemId/master.m3u8'
        '?MediaSourceId=s1'
        '${burns ? '&SubtitleStreamIndex=3&SubtitleMethod=Encode' : ''}',
      ),
      isDirectPlay: false,
      mediaSourceId: 's1',
    );
  }
}

const _ref = MediaRef(sourceId: 'server:p1', itemId: 'a1', title: 'Dune');

Future<List<int?>> _resolve({required bool burnIn}) async {
  final library = _TranscodingLibrary();
  final source = JellyfinMediaSource(
    library,
    preferences: () => StreamPreferences(burnInImageSubtitles: burnIn),
  );
  await source.resolve(_ref);
  return library.subtitleAsks;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('the transcode URL is what says a subtitle is burned in', () {
    expect(
      burnsInSubtitles(Uri.parse('https://h/x.m3u8?subtitleMethod=Encode')),
      isTrue,
    );
    expect(
      burnsInSubtitles(Uri.parse('https://h/x.m3u8?SubtitleMethod=Hls')),
      isFalse,
    );
    expect(burnsInSubtitles(Uri.parse('https://h/x.m3u8')), isFalse);
  });

  test('a capped profile hands text subtitles over and keeps image ones in',
      () {
    final profile = deviceProfileFor(
      const PlaybackCapabilities(maxBitrate: 4000000),
    )['DeviceProfile']! as Map<String, dynamic>;
    final subtitles =
        (profile['SubtitleProfiles']! as List).cast<Map<String, dynamic>>();

    String? method(String format, String m) => subtitles
        .where((p) => p['Format'] == format && p['Method'] == m)
        .map((p) => p['Method'] as String)
        .firstOrNull;

    // Direct play survives choosing any subtitle libmpv can draw.
    expect(method('pgssub', 'Embed'), 'Embed');
    expect(method('subrip', 'Embed'), 'Embed');
    // A transcode sends text beside the stream rather than painting it.
    expect(method('subrip', 'External'), 'External');
    expect(method('ass', 'External'), 'External');
    // An image subtitle has no way but burning in.
    expect(method('pgssub', 'External'), isNull);
  });

  test('burn-in on keeps the server\'s answer', () async {
    expect(await _resolve(burnIn: true), <int?>[null]);
  });

  test('burn-in off asks again with subtitles off', () async {
    expect(await _resolve(burnIn: false), <int?>[null, -1]);
  });

  testWidgets('the switch is saved', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = buildRouter();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: KumoApp(router: router),
      ),
    );
    await tester.pumpAndSettle();
    router.go('/settings/subtitle');
    await tester.pumpAndSettle();

    expect(container.read(burnInSubtitlesProvider), isTrue);
    final row = find.text('Burn in when transcoding');
    await tester.scrollUntilVisible(row, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(container.read(burnInSubtitlesProvider), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('burn_in_image_subtitles_v1'), isFalse);
  });
}

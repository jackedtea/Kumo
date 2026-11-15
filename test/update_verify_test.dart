// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/update_check.dart';
import 'package:kumo/core/updater.dart';

void main() {
  late Directory dir;
  late File file;
  const bytes = <int>[1, 2, 3, 4, 5, 6, 7, 8];
  final digest = sha256.convert(bytes).toString();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kumo-update-');
    file = File('${dir.path}/Kumo-setup.exe')..writeAsBytesSync(bytes);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  ReleaseAsset asset({int size = 8, String? sha}) => ReleaseAsset(
        name: 'Kumo-setup.exe',
        url: 'https://example.com/Kumo-setup.exe',
        size: size,
        sha256: sha,
      );

  group('a downloaded update', () {
    test('of the listed size and checksum is accepted', () async {
      await UpdateInstaller.verifyDownload(file, asset(sha: digest));
    });

    test('with no checksum published is judged on its size', () async {
      await UpdateInstaller.verifyDownload(file, asset());
      // A size GitHub did not give is not a size to fail on.
      await UpdateInstaller.verifyDownload(file, asset(size: 0));
    });

    test('cut short is refused', () async {
      await expectLater(
        UpdateInstaller.verifyDownload(file, asset(size: 9, sha: digest)),
        throwsA(isA<UpdateRejected>()),
      );
    });

    test('of the right size and the wrong contents is refused', () async {
      await expectLater(
        UpdateInstaller.verifyDownload(file, asset(sha: 'a' * 64)),
        throwsA(isA<UpdateRejected>()),
      );
    });
  });

  group("an asset's digest", () {
    ReleaseAsset parsed(Object? digest) => releaseFromJson(<String, Object?>{
          'tag_name': 'v1.3.0',
          'assets': <Object?>[
            <String, Object?>{
              'name': 'Kumo-setup.exe',
              'browser_download_url': 'https://example.com/Kumo-setup.exe',
              'size': 8,
              'digest': digest,
            },
          ],
        })!
            .assets
            .single;

    test('is read as lowercase hex', () {
      expect(parsed('sha256:${digest.toUpperCase()}').sha256, digest);
    });

    test('of another kind, or none, is no checksum', () {
      expect(parsed(null).sha256, isNull);
      expect(parsed('sha512:${'a' * 128}').sha256, isNull);
      expect(parsed('sha256:nothex').sha256, isNull);
    });
  });
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kumo/core/redact.dart';

void main() {
  test("mpv's own line about a stream it could not open loses the token", () {
    const line = 'Failed to open http://192.168.1.10:8096/Videos/abc/'
        'stream.mkv?static=true&ApiKey=0123456789abcdef&mediaSourceId=abc.';

    final shown = redactSecrets(line);

    expect(shown, isNot(contains('0123456789abcdef')));
    // The rest is what makes the line worth reading.
    expect(shown, contains('192.168.1.10:8096/Videos/abc/stream.mkv'));
    expect(shown, contains('ApiKey=<redacted>'));
    expect(shown, contains('mediaSourceId=abc'));
  });

  test('every spelling a server or a proxy uses is covered', () {
    for (final String name in <String>[
      'ApiKey',
      'apikey',
      'api_key',
      'access_token',
      'X-Emby-Token',
    ]) {
      expect(
        redactSecrets('GET /x?$name=s3cret&y=1'),
        'GET /x?$name=<redacted>&y=1',
        reason: name,
      );
    }
  });

  test('a token at the very end, or quoted, stops where it should', () {
    expect(redactSecrets('uri = http://h/a?ApiKey=tok'), endsWith('<redacted>'));
    expect(
      redactSecrets('open "http://h/a?ApiKey=tok" failed'),
      'open "http://h/a?ApiKey=<redacted>" failed',
    );
  });

  test('text with nothing secret in it is left as it was', () {
    const line = '[warn] ffmpeg: Could not find codec parameters (key=value)';
    expect(redactSecrets(line), line);
  });

  test('an exception that quotes its address is described without it', () {
    final error = HttpException(
      'Connection closed while receiving data',
      uri: Uri.parse('http://h:8096/Items/1/Download?ApiKey=tok123'),
    );

    expect('$error', contains('tok123'), reason: 'what dart:io prints');
    expect(describeError(error), isNot(contains('tok123')));
  });
}

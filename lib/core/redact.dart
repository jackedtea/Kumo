// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

/// Taking the server token out of text before it is shown, logged or sent.
///
/// A stream URL carries the token in its query (`ApiKey=…`) because libmpv
/// and a television fetch it themselves and cannot be handed a header. That
/// is fine for the URL and wrong for everything that *quotes* it: mpv says
/// "Failed to open http://…?ApiKey=…" when a stream will not open, a
/// `dart:io` `HttpException` ends in `uri = …`, and both used to travel as
/// they were — on to the player's error line, into the stats overlay's log,
/// to the system log, and to a phone remote as plain JSON over the LAN.
library;

/// `ApiKey` is what this app writes; the others are what a Jellyfin server
/// or a proxy in front of it may hand back in a URL of its own.
final RegExp _secretParameter = RegExp(
  r'''\b(api_?key|access_?token|x-emby-token|x-mediabrowser-token)=[^&\s"'<>]+''',
  caseSensitive: false,
);

/// [text] with the value of every token-bearing query parameter replaced.
///
/// The parameter's name stays, so a log still says a token was sent; only
/// what it was is gone.
String redactSecrets(String text) => text.replaceAllMapped(
      _secretParameter,
      (match) => '${match[1]}=<redacted>',
    );

/// [error] as text, for a log line or a sentence, without its secrets.
String describeError(Object? error) => redactSecrets('$error');

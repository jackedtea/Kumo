// Step 0 of docs/BOOKS_PLAN.md: does a Jellyfin server keep a book's
// position when it is written through UserData, and does a play-session
// report really throw it away?
//
// Uses dart:io only, so it runs with no pub get:
//
//   $env:KUMO_SPIKE_URL   = 'http://192.168.1.10:8096'
//   $env:KUMO_SPIKE_TOKEN = '<an access token or an API key>'
//   dart tool/book_position_spike.dart            # the UserData write
//   dart tool/book_position_spike.dart --trap     # also the session report
//
// Optional: KUMO_SPIKE_USER (a user id or name; needed with an API key,
// which belongs to no user) and KUMO_SPIKE_ITEM (a Book id; else the first
// one found). Whatever the book's state was, it is written back at the end —
// unless KUMO_SPIKE_KEEP=1, which leaves it at 50 % so the web reader can be
// opened to see where it lands. The real state waits in the system temp
// folder meanwhile, and the next run without KEEP puts it back.

import 'dart:convert';
import 'dart:io';

late final Uri _base;
late final String _token;
final HttpClient _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 10);

Future<void> main(List<String> args) async {
  final url = Platform.environment['KUMO_SPIKE_URL'];
  final token = Platform.environment['KUMO_SPIKE_TOKEN'];
  if (url == null || token == null) {
    stderr.writeln('Set KUMO_SPIKE_URL and KUMO_SPIKE_TOKEN first.');
    exit(64);
  }
  _base = Uri.parse(url.endsWith('/') ? url.substring(0, url.length - 1) : url);
  _token = token;
  final trap = args.contains('--trap');
  final keep = Platform.environment['KUMO_SPIKE_KEEP'] == '1';

  final info = await _json('GET', '/System/Info/Public');
  _say('Server', '${info['ServerName']} · Jellyfin ${info['Version']}');

  final userId = await _userId();
  _say('User', userId);

  final book = await _book(userId);
  final id = book['Id'] as String;
  final sources = (book['MediaSources'] as List?) ?? const <Object?>[];
  final container = sources.isEmpty
      ? null
      : (sources.first as Map<String, dynamic>)['Container'];
  _say('Book', '${book['Name']} ($id)');
  _say('  Type / MediaType', '${book['Type']} / ${book['MediaType']}');
  _say('  Container', '$container   Path ext: ${_ext(book['Path'])}');
  _say('  RunTimeTicks', '${book['RunTimeTicks']}');

  final download = await _status(
    'GET',
    '/Items/$id/Download',
    headers: <String, String>{'Range': 'bytes=0-0'},
  );
  _say(
    '  Download (Range 0-0)',
    '$download${download == 403 ? '  ← this account cannot read books' : ''}',
  );

  final before = await _original(id, await _userData(id, userId));
  _say('UserData before', _brief(before));

  var ok = true;
  try {
    // 1. The write the plan relies on: half way through an EPUB is
    //    0.5 × 10 000 000 ticks in jellyfin-web's encoding.
    const half = 5000000;
    final written = await _json(
      'POST',
      '/UserItems/$id/UserData',
      query: <String, String>{'userId': userId},
      body: <String, Object?>{
        'PlaybackPositionTicks': half,
        'Played': false,
        'LastPlayedDate': DateTime.now().toUtc().toIso8601String(),
      },
    );
    _say('POST UserData returned', _brief(written));
    final read = await _userData(id, userId);
    final kept =
        read['PlaybackPositionTicks'] == half && read['Played'] == false;
    ok &= kept;
    _say('Read back', '${_brief(read)}   ${kept ? 'PASS' : 'FAIL'}');

    // 2. Does it now show up where a Continue reading shelf would ask?
    final resume = await _json(
      'GET',
      '/UserItems/Resume',
      query: <String, String>{
        'userId': userId,
        'mediaTypes': 'Book',
        'limit': '50',
      },
    );
    final listed = ((resume['Items'] as List?) ?? const <Object?>[]).any(
      (Object? i) => (i as Map<String, dynamic>)['Id'] == id,
    );
    ok &= listed;
    _say('In /UserItems/Resume?mediaTypes=Book', listed ? 'PASS' : 'FAIL');

    // 3. The trap: a progress report on an item with no runtime.
    if (trap) {
      final status = await _status(
        'POST',
        '/Sessions/Playing/Progress',
        body: <String, Object?>{
          'ItemId': id,
          'PositionTicks': half,
          'IsPaused': true,
          'CanSeek': true,
        },
      );
      final after = await _userData(id, userId);
      final zeroed =
          after['Played'] == true || (after['PlaybackPositionTicks'] ?? 0) == 0;
      _say('Progress report ($status), then', _brief(after));
      _say(
        '  Session report destroys it',
        zeroed ? 'YES — never report books as plays' : 'no (plan can relax)',
      );
      // So the dashboard does not show this script as reading the book.
      await _status(
        'POST',
        '/Sessions/Playing/Stopped',
        body: <String, Object?>{'ItemId': id, 'PositionTicks': half},
      );
    }
  } finally {
    if (keep) {
      await _savedState(id).writeAsString(jsonEncode(before));
      _say(
        'Kept at 50 %',
        'open "${book['Name']}" in jellyfin-web now; '
            'rerun without KUMO_SPIKE_KEEP to put it back',
      );
    } else {
      await _restore(id, userId, before);
    }
  }
  _http.close();
  exit(ok ? 0 : 1);
}

/// Where a kept run leaves the book's real state, so the run that puts it
/// back does not mistake the 50 % it finds for the original.
File _savedState(String id) =>
    File('${Directory.systemTemp.path}/kumo_book_spike_$id.json');

/// The state to put back: the one a kept run saved, else what is there now.
Future<Map<String, dynamic>> _original(
  String id,
  Map<String, dynamic> current,
) async {
  final saved = _savedState(id);
  if (!saved.existsSync()) return current;
  _say('  (a kept run left this)', 'restoring the state saved before it');
  return jsonDecode(await saved.readAsString()) as Map<String, dynamic>;
}

Future<void> _restore(
  String id,
  String userId,
  Map<String, dynamic> before,
) async {
  final restored = await _json(
    'POST',
    '/UserItems/$id/UserData',
    query: <String, String>{'userId': userId},
    body: <String, Object?>{
      'PlaybackPositionTicks': before['PlaybackPositionTicks'] ?? 0,
      'Played': before['Played'] ?? false,
      'PlayCount': before['PlayCount'] ?? 0,
      'LastPlayedDate': ?before['LastPlayedDate'],
    },
  );
  _say('Restored', _brief(restored));
  if (before['LastPlayedDate'] == null) {
    _say('  Note', 'LastPlayedDate cannot be cleared through UserData');
  }
  final saved = _savedState(id);
  if (saved.existsSync()) saved.deleteSync();
}

Future<String> _userId() async {
  final wanted = Platform.environment['KUMO_SPIKE_USER'];
  if (wanted == null) {
    final me = await _json('GET', '/Users/Me');
    return me['Id'] as String;
  }
  final users = await _list('GET', '/Users');
  for (final u in users) {
    if (u['Id'] == wanted || u['Name'] == wanted) return u['Id'] as String;
  }
  throw StateError('No user "$wanted" on this server.');
}

Future<Map<String, dynamic>> _book(String userId) async {
  final wanted = Platform.environment['KUMO_SPIKE_ITEM'];
  final page = await _json(
    'GET',
    '/Items',
    query: <String, String>{
      'userId': userId,
      'ids': ?wanted,
      if (wanted == null) 'includeItemTypes': 'Book',
      'recursive': 'true',
      'limit': '1',
      'fields': 'MediaSources,Path',
    },
  );
  final items = (page['Items'] as List?) ?? const <Object?>[];
  if (items.isEmpty) throw StateError('No Book on this server for this user.');
  return items.first as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _userData(String id, String userId) => _json(
  'GET',
  '/UserItems/$id/UserData',
  query: <String, String>{'userId': userId},
);

String _brief(Map<String, dynamic> d) =>
    'position=${d['PlaybackPositionTicks']} played=${d['Played']} '
    'plays=${d['PlayCount']} lastPlayed=${d['LastPlayedDate']}';

String _ext(Object? path) {
  if (path is! String) return '—';
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '—' : path.substring(dot + 1);
}

void _say(String label, Object? value) =>
    stdout.writeln('${label.padRight(38)} $value');

Future<HttpClientResponse> _send(
  String method,
  String path, {
  Map<String, String>? query,
  Object? body,
  Map<String, String> headers = const <String, String>{},
}) async {
  final uri = _base.replace(
    path: '${_base.path}$path',
    queryParameters: query == null || query.isEmpty ? null : query,
  );
  final request = await _http.openUrl(method, uri);
  request.headers.set(
    'Authorization',
    'MediaBrowser Client="Kumo spike", Device="spike", DeviceId="kumo-spike", '
        'Version="0", Token="$_token"',
  );
  headers.forEach(request.headers.set);
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  return request.close();
}

Future<int> _status(
  String method,
  String path, {
  Object? body,
  Map<String, String> headers = const <String, String>{},
}) async {
  final response = await _send(method, path, body: body, headers: headers);
  await response.drain<void>();
  return response.statusCode;
}

Future<Map<String, dynamic>> _json(
  String method,
  String path, {
  Map<String, String>? query,
  Object? body,
}) async {
  final decoded = await _decode(method, path, query: query, body: body);
  return decoded as Map<String, dynamic>;
}

Future<List<Map<String, dynamic>>> _list(String method, String path) async {
  final decoded = await _decode(method, path);
  return (decoded as List).cast<Map<String, dynamic>>();
}

Future<Object?> _decode(
  String method,
  String path, {
  Map<String, String>? query,
  Object? body,
}) async {
  final response = await _send(method, path, query: query, body: body);
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode >= 400) {
    throw HttpException('$method $path → ${response.statusCode} $text');
  }
  return text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
}

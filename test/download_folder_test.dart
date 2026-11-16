// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kumo/downloads/download_folder.dart';
import 'package:kumo/downloads/download_models.dart';
import 'package:kumo/downloads/download_platform.dart';
import 'package:kumo/downloads/download_settings.dart';
import 'package:kumo/downloads/download_store.dart';
import 'package:kumo/downloads/downloads_controller.dart';
import 'package:kumo/features/downloads/download_folder_picker.dart';
import 'package:kumo/l10n/app_localizations.dart';
import 'package:kumo/servers/media_library_source.dart';

const _film = ServerItem(id: 'i1', title: 'The Film', kind: ServerItemKind.movie);
const _other = ServerItem(id: 'i2', title: 'Another', kind: ServerItemKind.movie);

class _NoPlatform extends DownloadPlatform {
  @override
  bool get enabled => false;
}

class _Picker extends DownloadFolderPicker {
  _Picker(this.answer);

  final String? answer;
  int asked = 0;

  @override
  Future<String?> pick(BuildContext context) async {
    asked++;
    return answer;
  }
}

/// A whole copy of [item] in [store], on disk and in its index.
Future<DownloadEntry> _copy(DownloadStore store, ServerItem item) async {
  final entry = DownloadEntry.fromItem('p1', item).copyWith(
    status: DownloadStatus.completed,
    fileName: 'media.mkv',
    receivedBytes: 4,
  );
  final file = store.mediaFile(entry)!;
  await file.parent.create(recursive: true);
  await file.writeAsBytes(<int>[1, 2, 3, 4]);
  return entry;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kumo_dlfolder_');
  });

  tearDown(() async {
    try {
      if (temp.existsSync()) await temp.delete(recursive: true);
    } on FileSystemException catch (_) {}
  });

  test('the copies go in a Kumo folder, once', () {
    final picked = p.join(temp.path, 'Videos');
    final root = downloadRootIn(picked);
    expect(root, p.join(picked, 'Kumo'));
    expect(downloadRootIn(root), root);
  });

  test('moving takes everything, into a folder inside the old one too', () async {
    final from = Directory(p.join(temp.path, 'old'));
    await File(p.join(from.path, 'p1', 'i1', 'media.mkv')).create(recursive: true);
    await File(p.join(from.path, 'index.json')).writeAsString('[]');
    final to = Directory(p.join(from.path, 'Kumo'));

    await moveFolderContents(from, to);

    expect(File(p.join(to.path, 'p1', 'i1', 'media.mkv')).existsSync(), isTrue);
    expect(File(p.join(to.path, 'index.json')).existsSync(), isTrue);
    expect(Directory(p.join(from.path, 'p1')).existsSync(), isFalse);
    expect(Directory(p.join(to.path, 'Kumo')).existsSync(), isFalse);
  });

  test('moving merges into item folders already there', () async {
    final from = Directory(p.join(temp.path, 'old'));
    final to = Directory(p.join(temp.path, 'new'));
    await File(p.join(from.path, 'p1', 'i1', 'media.mkv')).create(recursive: true);
    await File(p.join(to.path, 'p1', 'i2', 'media.mkv')).create(recursive: true);

    await moveFolderContents(from, to);

    expect(File(p.join(to.path, 'p1', 'i1', 'media.mkv')).existsSync(), isTrue);
    expect(File(p.join(to.path, 'p1', 'i2', 'media.mkv')).existsSync(), isTrue);
  });

  group('the controller', () {
    late Directory oldRoot;
    late Directory newRoot;

    setUp(() {
      oldRoot = Directory(p.join(temp.path, 'old'));
      newRoot = Directory(p.join(temp.path, 'new', 'Kumo'));
      SharedPreferences.setMockInitialValues(<String, Object>{
        'downloads_folder_v1': oldRoot.path,
      });
    });

    ProviderContainer container() {
      final c = ProviderContainer(
        overrides: [
          downloadSourceProvider.overrideWithValue((_) => null),
          downloadNetworkProvider
              .overrideWith((ref) => const Stream<DownloadNetwork>.empty()),
          downloadPlatformProvider.overrideWithValue(_NoPlatform()),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('opens the chosen folder', () async {
      final c = container();
      final store = await c.read(downloadStoreProvider.future);
      expect(store.root.path, oldRoot.path);
    });

    test('moveTo carries the copies and remembers the folder', () async {
      final old = DownloadStore(oldRoot);
      final entry = await _copy(old, _film);
      await old.save(<DownloadEntry>[entry]);

      final c = container();
      final controller = c.read(downloadsProvider.notifier);
      await controller.ready;
      expect(c.read(downloadsProvider), hasLength(1));

      await controller.moveTo(newRoot.path);

      expect(await c.read(downloadFolderProvider.future), newRoot.path);
      expect(controller.store!.root.path, newRoot.path);
      final moved = c.read(downloadsProvider).single;
      expect(controller.store!.mediaFile(moved)!.existsSync(), isTrue);
      expect(old.mediaFile(entry)!.existsSync(), isFalse);
      expect(await DownloadStore(newRoot).load(), hasLength(1));
    });

    test('moveTo keeps the copies a folder used before still lists', () async {
      final old = DownloadStore(oldRoot);
      await old.save(<DownloadEntry>[await _copy(old, _film)]);
      final before = DownloadStore(newRoot);
      await before.save(<DownloadEntry>[await _copy(before, _other)]);

      final c = container();
      final controller = c.read(downloadsProvider.notifier);
      await controller.ready;
      await controller.moveTo(newRoot.path);

      expect(
        c.read(downloadsProvider).map((e) => e.itemId).toSet(),
        <String>{'i1', 'i2'},
      );
      expect(await DownloadStore(newRoot).load(), hasLength(2));
    });

    test('a folder that cannot be made leaves everything where it was', () async {
      final old = DownloadStore(oldRoot);
      final entry = await _copy(old, _film);
      await old.save(<DownloadEntry>[entry]);
      // A file where the folder would have to be.
      final blocked = File(p.join(temp.path, 'blocked'));
      await blocked.writeAsString('x');

      final c = container();
      final controller = c.read(downloadsProvider.notifier);
      await controller.ready;

      await expectLater(
        controller.moveTo(p.join(blocked.path, 'Kumo')),
        throwsA(isA<FileSystemException>()),
      );
      expect(await c.read(downloadFolderProvider.future), oldRoot.path);
      expect(old.mediaFile(entry)!.existsSync(), isTrue);
      expect(c.read(downloadsProvider), hasLength(1));
    });
  });

  group('the gate', () {
    Future<(WidgetRef, BuildContext)> pump(
      WidgetTester tester,
      _Picker picker,
    ) async {
      late WidgetRef ref;
      late BuildContext context;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadFolderPickerProvider.overrideWithValue(picker),
            downloadSourceProvider.overrideWithValue((_) => null),
            downloadNetworkProvider
                .overrideWith((ref) => const Stream<DownloadNetwork>.empty()),
            downloadPlatformProvider.overrideWithValue(_NoPlatform()),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const <LocalizationsDelegate<Object>>[
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (c, r, _) {
                  context = c;
                  ref = r;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      return (ref, context);
    }

    testWidgets('a folder already chosen is not asked for again', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'downloads_folder_v1': p.join(temp.path, 'chosen'),
      });
      final picker = _Picker(null);
      final (ref, context) = await pump(tester, picker);

      final ok = await tester.runAsync(() => ensureDownloadFolder(context, ref));
      expect(ok, isTrue);
      expect(picker.asked, 0);
    });

    testWidgets('backing out queues nothing and says why', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final picker = _Picker(null);
      final (ref, context) = await pump(tester, picker);

      final ok = await tester.runAsync(() => ensureDownloadFolder(context, ref));
      await tester.pump();
      expect(ok, isFalse);
      expect(picker.asked, 1);
      expect(find.text('Choose a download folder first.'), findsOneWidget);
    });
  });
}

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// The folder the app keeps its copies in under one the user picked.
///
/// A subfolder, so the index and the id-named item folders do not land among
/// the user's own files. Picking that subfolder itself — choosing the same
/// place again — does not nest a second one inside it.
const downloadFolderName = 'Kumo';

String downloadRootIn(String picked) => p.basename(picked) == downloadFolderName
    ? picked
    : p.join(picked, downloadFolderName);

/// Whether [a] and [b] name the same folder.
bool sameFolder(String a, String b) {
  final x = p.normalize(p.absolute(a));
  final y = p.normalize(p.absolute(b));
  return Platform.isWindows ? x.toLowerCase() == y.toLowerCase() : x == y;
}

/// Moves everything in [from] into [to], which is created.
///
/// A rename where the two share a volume, which costs nothing; a copy and a
/// delete where they do not. All or nothing as far as it can be: when a
/// child fails, the ones already moved are put back and the error rethrown,
/// so the caller can go on using [from] as if it had never been asked.
///
/// [to] may sit inside [from] (the `Kumo` subfolder of the folder in use);
/// it is skipped rather than moved into itself. A file already in [to] under
/// the same name is replaced.
Future<void> moveFolderContents(Directory from, Directory to) async {
  await to.create(recursive: true);
  if (!await from.exists() || sameFolder(from.path, to.path)) return;

  final moved = <(String, String)>[];
  try {
    await for (final FileSystemEntity child in from.list()) {
      if (sameFolder(child.path, to.path)) continue;
      final target = p.join(to.path, p.basename(child.path));
      // Listed before it is moved: one that fails half way across is put
      // back with the rest.
      moved.add((child.path, target));
      await _move(child, target);
    }
  } on Object {
    for (final (String source, String target) in moved.reversed) {
      try {
        final type = await FileSystemEntity.type(target);
        if (type == FileSystemEntityType.notFound) continue;
        await _move(
          type == FileSystemEntityType.directory
              ? Directory(target)
              : File(target),
          source,
        );
      } on Object catch (e) {
        debugPrint('Could not put $target back: $e');
      }
    }
    rethrow;
  }
}

Future<void> _move(FileSystemEntity entity, String target) async {
  if (entity is Directory) {
    final existing = Directory(target);
    if (!await existing.exists()) {
      try {
        await entity.rename(target);
        return;
      } on FileSystemException {
        // Another volume: copied below.
      }
    }
    // Merged into what is there, or copied across volumes, child by child.
    await existing.create(recursive: true);
    await for (final FileSystemEntity child in entity.list()) {
      await _move(child, p.join(target, p.basename(child.path)));
    }
    await entity.delete(recursive: true);
    return;
  }
  if (entity is! File) return;
  try {
    await entity.rename(target);
  } on FileSystemException {
    try {
      await entity.copy(target);
    } on Object {
      // Half a film at the destination is worse than none.
      try {
        await File(target).delete();
      } on Object catch (_) {}
      rethrow;
    }
    await entity.delete();
  }
}

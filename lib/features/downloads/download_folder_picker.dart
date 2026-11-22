// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../downloads/download_folder.dart';
import '../../downloads/download_settings.dart';
import '../../downloads/downloads_controller.dart';
import '../../l10n/app_localizations.dart';

/// Asks the user where downloads go. Overridden in tests, which have no
/// system dialog to answer.
final downloadFolderPickerProvider =
    Provider<DownloadFolderPicker>((ref) => const DownloadFolderPicker());

/// One place downloads can be kept, where the choice is a list.
@immutable
class DownloadVolume {
  const DownloadVolume({required this.path, required this.removable});

  final String path;

  /// A card or a drive that can be taken out, rather than the device's own.
  final bool removable;
}

class DownloadFolderPicker {
  const DownloadFolderPicker();

  /// The folder to keep copies in, or null when the user backed out.
  ///
  /// Windows and Linux hand over any folder, and the copies go in a `Kumo`
  /// folder inside it. Everywhere else the engine writes and the player
  /// reads plain files, which rules out a folder the system would hand over
  /// as a document tree — so the choice is between the places the app may
  /// write: the device's own storage and each card.
  Future<String?> pick(BuildContext context) async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      final l10n = AppLocalizations.of(context);
      final picked = await getDirectoryPath(
        confirmButtonText: l10n.downloadFolderChoose,
      );
      return picked == null ? null : downloadRootIn(picked);
    }

    final volumes = await this.volumes();
    if (!context.mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (context) => _VolumeDialog(volumes: volumes),
    );
  }

  /// The device's own storage first, then whatever can be taken out.
  Future<List<DownloadVolume>> volumes() async {
    final own = await appDownloadsDirectory();
    final found = <DownloadVolume>[
      DownloadVolume(path: own.path, removable: false),
    ];
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final external = await getExternalStorageDirectories();
        for (final Directory dir in external ?? const <Directory>[]) {
          // The first is the device's own shared storage under another
          // name; "emulated" is how Android spells that.
          if (dir.path.contains('/emulated/')) continue;
          found.add(
            DownloadVolume(path: p.join(dir.path, 'downloads'), removable: true),
          );
        }
      } on Object catch (e) {
        debugPrint('Could not list the storage volumes: $e');
      }
    }
    return found;
  }
}

class _VolumeDialog extends StatelessWidget {
  const _VolumeDialog({required this.volumes});

  final List<DownloadVolume> volumes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SimpleDialog(
      title: Text(l10n.downloadFolderChoose),
      children: <Widget>[
        for (final DownloadVolume v in volumes)
          ListTile(
            leading: Icon(
              v.removable ? Icons.sd_card_outlined : Icons.smartphone_rounded,
            ),
            title: Text(
              v.removable ? l10n.downloadFolderCard : l10n.downloadFolderDevice,
            ),
            subtitle: Text(v.path, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.of(context).pop(v.path),
          ),
      ],
    );
  }
}

/// Makes sure there is a download folder, asking for one when there is not.
///
/// False means nothing may be queued: the user backed out of the choice, or
/// the folder they chose could not be used. Either way they have been told.
Future<bool> ensureDownloadFolder(BuildContext context, WidgetRef ref) async {
  final current = await ref.read(downloadFolderProvider.future);
  if (current != null) return true;
  if (!context.mounted) return false;
  return chooseDownloadFolder(context, ref, required: true);
}

/// Asks for a folder and moves the downloads into it. True when it is now
/// the folder in use.
///
/// [required] says a download is waiting on the answer, so backing out is
/// answered with why nothing was queued.
Future<bool> chooseDownloadFolder(
  BuildContext context,
  WidgetRef ref, {
  bool required = false,
}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context, rootNavigator: true);
  final controller = ref.read(downloadsProvider.notifier);

  final picked = await ref.read(downloadFolderPickerProvider).pick(context);
  if (picked == null) {
    if (required) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.downloadFolderRequired)));
    }
    return false;
  }

  // Moving copies between drives takes as long as copying them does.
  var moving = false;
  if (controller.entries.isNotEmpty && context.mounted) {
    moving = true;
    unawaited(
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: <Widget>[
                const CircularProgressIndicator(),
                const SizedBox(width: 24),
                Expanded(child: Text(l10n.downloadFolderMoving)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  try {
    await controller.moveTo(picked);
    return true;
  } on Object catch (e) {
    debugPrint('Could not use $picked for downloads: $e');
    messenger.showSnackBar(SnackBar(content: Text(l10n.downloadFolderFailed)));
    return false;
  } finally {
    if (moving) navigator.pop();
  }
}

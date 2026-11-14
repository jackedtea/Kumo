// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../servers/media_library_source.dart';
import '../../servers/stream_preferences.dart';
import '../player/playback_controller.dart';
import '../player/player_ui_state.dart';
import 'player_settings.dart';
import '../../l10n/app_localizations.dart';
import 'settings_widgets.dart';

/// Screen 1l, Player section.
///
/// Every control here writes through to [playerSettingsProvider], which is
/// persisted and applied to libmpv immediately — a switch that only moved a
/// local bool would be worse than no switch at all.
class PlayerSettingsPage extends ConsumerWidget {
  const PlayerSettingsPage({super.key});

  /// The amounts the transport buttons and double-tap gestures offer.
  static const _skipChoices = <int>[5, 10, 15, 30, 60];

  /// A/V sync offsets, in milliseconds. Negative plays the audio earlier,
  /// which is as common a fault as the other way round.
  static const audioDelayChoices = <int>[
    -1000, -500, -250, -100, 0, 100, 250, 500, 1000,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(playerSettingsProvider);

    Future<void> save(PlayerSettings next) async {
      await ref.read(playerSettingsProvider.notifier).update(next);
      // Takes effect mid-playback rather than on the next file.
      await ref.read(playbackControllerProvider.notifier).applySettings(next);
    }

    return SettingsScaffold(
      title: AppLocalizations.of(context).settingsPlayer,
      children: <Widget>[
        SettingsSection(title: AppLocalizations.of(context).playback),
        SettingsValueRow(
          title: AppLocalizations.of(context).hardwareDecoding,
          value: settings.hardwareDecoding.label(AppLocalizations.of(context)),
          subtitle: AppLocalizations.of(context).hardwareDecodingFallback,
          onTap: () => _pickHardwareDecoding(context, settings, save),
        ),
        SettingsValueRow(
          title: AppLocalizations.of(context).skipBack,
          value: '${settings.skipBack.inSeconds}s',
          onTap: () => _pickSkip(
            context,
            settings.skipBack,
            (d) => save(settings.copyWith(skipBack: d)),
          ),
        ),
        SettingsValueRow(
          title: AppLocalizations.of(context).skipForward,
          value: '${settings.skipForward.inSeconds}s',
          onTap: () => _pickSkip(
            context,
            settings.skipForward,
            (d) => save(settings.copyWith(skipForward: d)),
          ),
        ),
        SettingsValueRow(
          title: AppLocalizations.of(context).audioDelay,
          value: formatDelay(settings.audioDelay),
          subtitle: AppLocalizations.of(context).audioDelaySub,
          onTap: () => pickAudioDelay(
            context,
            settings.audioDelay,
            (d) => save(settings.copyWith(audioDelay: d)),
          ),
        ),
        SettingsSwitchRow(
          title: AppLocalizations.of(context).autoPlayNext,
          subtitle: AppLocalizations.of(context).autoPlayNextSub,
          value: settings.autoPlayNext,
          onChanged: (v) => save(settings.copyWith(autoPlayNext: v)),
        ),
        // The server's media segments (Jellyfin 10.10 and later), or chapters
        // titled OP, ED, Preview… where it has none. Shown whatever is
        // configured: a setting
        // that appears only once a server happens to be signed in is a
        // setting nobody finds, and the rows are harmless with none.
        SettingsSection(title: AppLocalizations.of(context).serverSegments),
        SettingsNote(AppLocalizations.of(context).serverSegmentsSub),
        for (final MediaSegmentKind kind in supportedSegmentKinds)
          SettingsValueRow(
            title: segmentKindLabel(context, kind),
            value: segmentActionLabel(context, settings.actionFor(kind)),
            onTap: () => _pickSegmentAction(context, settings, kind, save),
          ),
        SettingsSection(title: AppLocalizations.of(context).screenAndGestures),
        // Both are Android behaviours with no desktop equivalent, so the rows
        // are absent rather than present and inert.
        if (Platform.isAndroid) ...<Widget>[
          SettingsSwitchRow(
            title: AppLocalizations.of(context).pictureInPicture,
            subtitle: AppLocalizations.of(context).pictureInPictureSub,
            value: settings.pipOnLeave,
            onChanged: (v) => save(settings.copyWith(pipOnLeave: v)),
          ),
          SettingsSwitchRow(
            title: AppLocalizations.of(context).backgroundAudio,
            subtitle: AppLocalizations.of(context).backgroundAudioSub,
            value: settings.backgroundAudio,
            onChanged: (v) => save(settings.copyWith(backgroundAudio: v)),
          ),
        ],
        SettingsSwitchRow(
          title: AppLocalizations.of(context).swipeGestures,
          subtitle: AppLocalizations.of(context).swipeGesturesSub,
          value: settings.swipeGestures,
          onChanged: (v) => save(settings.copyWith(swipeGestures: v)),
        ),
        // A desktop window has no orientation to hold.
        if (Platform.isAndroid || Platform.isIOS)
          SettingsValueRow(
            title: AppLocalizations.of(context).rotation,
            value: _rotationLabel(context, settings.defaultRotation),
            onTap: () => _pickRotation(context, settings, save),
          ),
        // The most Auto may use on each network. The player's quality pill
        // still picks a rung for the film on screen, and Auto there means
        // these.
        SettingsSection(title: AppLocalizations.of(context).streamingQuality),
        SettingsNote(AppLocalizations.of(context).qualityCapSub),
        _QualityCapRow(metered: false),
        _QualityCapRow(metered: true),
      ],
    );
  }

  static String _rotationLabel(BuildContext context, RotationMode mode) {
    final l10n = AppLocalizations.of(context);
    return mode == RotationMode.auto ? l10n.followVideo : mode.label(l10n);
  }

  Future<void> _pickRotation(
    BuildContext context,
    PlayerSettings settings,
    Future<void> Function(PlayerSettings) save,
  ) async {
    final chosen = await showModalBottomSheet<RotationMode>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final RotationMode mode in RotationMode.values)
              ListTile(
                leading: Icon(mode.icon),
                title: Text(_rotationLabel(sheetContext, mode)),
                trailing: mode == settings.defaultRotation
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(mode),
              ),
          ],
        ),
      ),
    );

    if (chosen == null) return;
    await save(settings.copyWith(defaultRotation: chosen));
  }

  Future<void> _pickHardwareDecoding(
    BuildContext context,
    PlayerSettings settings,
    Future<void> Function(PlayerSettings) save,
  ) async {
    final chosen = await showModalBottomSheet<HardwareDecoding>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final HardwareDecoding mode in HardwareDecoding.values)
              ListTile(
                title: Text(mode.label(AppLocalizations.of(sheetContext))),
                // Which of the three to reach for is the whole question, and
                // the names alone do not answer it.
                subtitle: Text(
                  mode.description(AppLocalizations.of(sheetContext)),
                ),
                isThreeLine: false,
                trailing: mode == settings.hardwareDecoding
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(mode),
              ),
          ],
        ),
      ),
    );

    if (chosen == null) return;
    await save(settings.copyWith(hardwareDecoding: chosen));
  }

  Future<void> _pickSegmentAction(
    BuildContext context,
    PlayerSettings settings,
    MediaSegmentKind kind,
    Future<void> Function(PlayerSettings) save,
  ) async {
    final chosen = await showModalBottomSheet<SegmentAction>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final SegmentAction action in SegmentAction.values)
              ListTile(
                title: Text(segmentActionLabel(sheetContext, action)),
                trailing: action == settings.actionFor(kind)
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(action),
              ),
          ],
        ),
      ),
    );

    if (chosen == null) return;

    await save(
      settings.copyWith(
        segmentActions: <MediaSegmentKind, SegmentAction>{
          ...settings.segmentActions,
          kind: chosen,
        },
      ),
    );
  }

  Future<void> _pickSkip(
    BuildContext context,
    Duration current,
    Future<void> Function(Duration) save,
  ) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final int seconds in _skipChoices)
              ListTile(
                title: Text(
                  AppLocalizations.of(sheetContext).seconds(seconds),
                ),
                trailing: seconds == current.inSeconds
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(seconds),
              ),
          ],
        ),
      ),
    );

    if (chosen == null) return;
    await save(Duration(seconds: chosen));
  }
}

/// Auto's cap on one kind of network, and the sheet that changes it.
class _QualityCapRow extends ConsumerWidget {
  const _QualityCapRow({required this.metered});

  /// Mobile data rather than Wi-Fi.
  final bool metered;

  static String _label(AppLocalizations l10n, StreamQuality q) =>
      q.isOriginal ? l10n.qualityNoLimit : q.label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final defaults = ref.watch(streamQualityDefaultsProvider);
    final current = defaults.forNetwork(metered: metered);

    return SettingsValueRow(
      title: metered ? l10n.onCellular : l10n.onWifi,
      value: _label(l10n, current),
      onTap: () => _pick(context, ref, current),
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    StreamQuality current,
  ) async {
    final chosen = await showModalBottomSheet<StreamQuality>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final l10n = AppLocalizations.of(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final StreamQuality q in streamQualities)
                ListTile(
                  title: Text(_label(l10n, q)),
                  trailing: q.id == current.id
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(q),
                ),
            ],
          ),
        );
      },
    );

    if (chosen == null) return;
    final defaults = ref.read(streamQualityDefaultsProvider.notifier);
    await (metered ? defaults.setCellular(chosen) : defaults.setWifi(chosen));
  }
}

/// What each kind of segment is called on the settings page.
///
/// The viewer's words, not the server's: "Closing credits" rather than
/// "Outro", and "Advert" rather than "Commercial". Nobody scanning a settings
/// list should have to learn a schema to use it.
String segmentKindLabel(BuildContext context, MediaSegmentKind kind) {
  final l10n = AppLocalizations.of(context);
  return switch (kind) {
    MediaSegmentKind.intro => l10n.segmentIntro,
    MediaSegmentKind.outro => l10n.segmentOutro,
    MediaSegmentKind.recap => l10n.segmentRecap,
    MediaSegmentKind.preview => l10n.segmentPreview,
    MediaSegmentKind.commercial => l10n.segmentCommercial,
    // Never listed — `supportedSegmentKinds` is what the page iterates.
    MediaSegmentKind.unknown => l10n.segmentIntro,
  };
}

String segmentActionLabel(BuildContext context, SegmentAction action) {
  final l10n = AppLocalizations.of(context);
  return switch (action) {
    SegmentAction.nothing => l10n.segmentActionNothing,
    SegmentAction.askToSkip => l10n.segmentActionAsk,
    SegmentAction.skip => l10n.segmentActionSkip,
  };
}

/// "+250 ms", "0 ms". The sign is always shown for a non-zero value: which
/// direction the offset goes is the whole point of the number.
String formatDelay(Duration delay) {
  final ms = delay.inMilliseconds;
  if (ms == 0) return '0 ms';
  return '${ms > 0 ? '+' : ''}$ms ms';
}

/// Shared by the settings page and the player's overflow menu — A/V sync is
/// something you fix while watching, not before.
Future<void> pickAudioDelay(
  BuildContext context,
  Duration current,
  Future<void> Function(Duration) save,
) async {
  final chosen = await showModalBottomSheet<int>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          for (final int ms in PlayerSettingsPage.audioDelayChoices)
            ListTile(
              title: Text(formatDelay(Duration(milliseconds: ms))),
              trailing: ms == current.inMilliseconds
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.of(sheetContext).pop(ms),
            ),
        ],
      ),
    ),
  );

  if (chosen == null) return;
  await save(Duration(milliseconds: chosen));
}

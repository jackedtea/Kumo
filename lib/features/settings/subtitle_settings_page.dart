// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/tokens.dart';
import '../../core/languages.dart';
import '../player/playback_controller.dart';
import '../player/subtitle_fonts.dart';
import '../../servers/stream_preferences.dart' show burnInSubtitlesProvider;
import 'player_settings.dart';
import '../../l10n/app_localizations.dart';
import 'settings_widgets.dart';

/// Screen 1m, Subtitle.
///
/// The preview is the point of this page: every control above the fold
/// changes it live, so the user never has to start playback to judge a
/// setting.
class SubtitleSettingsPage extends ConsumerStatefulWidget {
  const SubtitleSettingsPage({super.key});

  @override
  ConsumerState<SubtitleSettingsPage> createState() =>
      _SubtitleSettingsPageState();
}

class _SubtitleSettingsPageState extends ConsumerState<SubtitleSettingsPage> {
  static const _colours = <Color>[
    Colors.white,
    Color(0xFFFFE082),
    Color(0xFF8FD8C6),
    Color(0xFF82CFFF),
    Color(0xFFFFAB91),
  ];

  /// Writes through and applies to libmpv straight away, so the live preview
  /// and the actual subtitles cannot disagree.
  Future<void> _save(PlayerSettings next) async {
    await ref.read(playerSettingsProvider.notifier).update(next);
    await ref.read(playbackControllerProvider.notifier).applySettings(next);
  }

  /// The language the user reads in, which drives both track choices.
  ///
  /// Applied to the running file straight away rather than at the next open:
  /// someone changing this mid-film is changing it *because* of that film.
  Future<void> _pickLanguage(PlayerSettings settings) async {
    final chosen = await showModalBottomSheet<_LanguageChoice>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              title: Text(AppLocalizations.of(context).noPreference),
              subtitle: Text(AppLocalizations.of(context).noPreferenceSub),
              trailing: settings.preferredLanguage == null
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () =>
                  Navigator.of(sheetContext).pop(const _LanguageChoice(null)),
            ),
            for (final LanguageOption option in languageOptions)
              ListTile(
                title: Text(option.label),
                trailing: option.code == settings.preferredLanguage
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext)
                    .pop(_LanguageChoice(option.code)),
              ),
          ],
        ),
      ),
    );

    // Null means the sheet was dismissed; a choice of "no preference" is a
    // wrapper holding null, which is a different thing entirely.
    if (chosen == null) return;

    await _save(
      settings.copyWith(
        preferredLanguage: chosen.code,
        clearPreferredLanguage: chosen.code == null,
      ),
    );
    await ref.read(playbackControllerProvider.notifier).applySmartSubtitles();
  }

  /// Desktops, where libass can reach every font installed on the machine.
  /// Android's libass sees only what the app carries.
  static bool get _systemFontsReachable =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> _pickFont(PlayerSettings settings) async {
    final current = settings.subtitleFont;
    final custom = isBundledSubtitleFont(current) ? null : current;

    // A family name, or the empty string for "type one".
    final chosen = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final l10n = AppLocalizations.of(sheetContext);
        Widget row(String family, {String? subtitle}) => ListTile(
              // Each name in its own face: choosing a font by its name alone
              // is choosing blind.
              title: Text(family, style: TextStyle(fontFamily: family)),
              subtitle: subtitle == null ? null : Text(subtitle),
              trailing: family == current
                  ? const Icon(Icons.check_rounded)
                  : null,
              onTap: () => Navigator.of(sheetContext).pop(family),
            );

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              for (final BundledSubtitleFont f in bundledSubtitleFonts)
                row(f.family),
              if (custom != null) row(custom, subtitle: l10n.fontInstalled),
              if (_systemFontsReachable)
                ListTile(
                  leading: const Icon(Icons.font_download_outlined),
                  title: Text(l10n.fontOther),
                  onTap: () => Navigator.of(sheetContext).pop(''),
                ),
            ],
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;

    final family = chosen.isEmpty ? await _askFontName(custom) : chosen;
    if (family == null || family.isEmpty) return;
    await _save(settings.copyWith(subtitleFont: family));
  }

  Future<String?> _askFontName(String? initial) {
    return showDialog<String>(
      context: context,
      builder: (_) => _FontNameDialog(initial: initial),
    );
  }

  Future<void> _pickDelay(PlayerSettings settings) async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final int ms in _delayChoices)
              ListTile(
                title: Text(AppLocalizations.of(sheetContext).milliseconds(ms)),
                trailing: ms == settings.subtitleDelay.inMilliseconds
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(ms),
              ),
          ],
        ),
      ),
    );

    if (chosen == null) return;
    await _save(
      settings.copyWith(subtitleDelay: Duration(milliseconds: chosen)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final spacing = context.spacing;
    final settings = ref.watch(playerSettingsProvider);
    final colourIndex = _colours.indexWhere(
      (c) => c.toARGB32() == settings.subtitleColour.toARGB32(),
    );

    return SettingsScaffold(
      title: l10n.settingsSubtitle,
      children: <Widget>[
        _Preview(
          textScale: settings.subtitleTextScale,
          backgroundOpacity: settings.subtitleBackgroundOpacity,
          colour: settings.subtitleColour,
          font: settings.subtitleFont,
        ),
        SettingsSection(title: l10n.style),
        SettingsValueRow(
          title: l10n.font,
          value: settings.subtitleFont,
          subtitle: l10n.subtitleFontSub,
          onTap: () => _pickFont(settings),
        ),
        SettingsSliderRow(
          title: l10n.textSize,
          valueLabel: '${(settings.subtitleTextScale * 100).round()}%',
          value: settings.subtitleTextScale,
          min: 0.5,
          max: 2.0,
          divisions: 15,
          onChanged: (v) => _save(settings.copyWith(subtitleTextScale: v)),
        ),
        SettingsSliderRow(
          title: l10n.backgroundOpacity,
          valueLabel:
              '${(settings.subtitleBackgroundOpacity * 100).round()}%',
          value: settings.subtitleBackgroundOpacity,
          divisions: 20,
          onChanged: (v) =>
              _save(settings.copyWith(subtitleBackgroundOpacity: v)),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            spacing.screenHorizontal(context.windowSize),
            spacing.md,
            spacing.screenHorizontal(context.windowSize),
            0,
          ),
          child: Wrap(
            spacing: spacing.md,
            children: <Widget>[
              for (final (int i, Color c) in _colours.indexed)
                InkWell(
                  onTap: () => _save(settings.copyWith(subtitleColour: c)),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: context.colors.outline),
                    ),
                    child: i == colourIndex
                        ? const Icon(Icons.check_rounded,
                            size: 20, color: Colors.black)
                        : null,
                  ),
                ),
            ],
          ),
        ),
        SettingsSection(title: l10n.behaviour),
        SettingsValueRow(
          title: l10n.preferredLanguage,
          value: languageLabel(settings.preferredLanguage),
          subtitle: l10n.preferredLanguageSub,
          onTap: () => _pickLanguage(settings),
        ),
        SettingsSwitchRow(
          title: l10n.smartSubtitles,
          subtitle: l10n.smartSubtitlesSub,
          value: settings.smartSubtitles,
          onChanged: (v) => _save(settings.copyWith(smartSubtitles: v)),
        ),
        SettingsSwitchRow(
          title: l10n.burnInWhenTranscoding,
          subtitle: l10n.imageBasedOnly,
          value: ref.watch(burnInSubtitlesProvider),
          onChanged: (v) => ref.read(burnInSubtitlesProvider.notifier).set(v),
        ),
        SettingsValueRow(
          title: l10n.syncOffset,
          value: '${settings.subtitleDelay.inMilliseconds} ms',
          subtitle: l10n.syncOffsetSub,
          onTap: () => _pickDelay(settings),
        ),
      ],
    );
  }
}

/// A short list rather than free text: the useful range is small, and a
/// numeric keyboard for milliseconds is a poor way to nudge timing.
const _delayChoices = <int>[-2000, -1000, -500, 0, 500, 1000, 2000];

class _Preview extends StatelessWidget {
  const _Preview({
    required this.textScale,
    required this.backgroundOpacity,
    required this.colour,
    required this.font,
  });

  final double textScale;
  final double backgroundOpacity;
  final Color colour;
  final String font;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;

    return Container(
      height: 132,
      margin: EdgeInsets.symmetric(
        horizontal: spacing.screenHorizontal(context.windowSize),
      ),
      decoration: BoxDecoration(
        borderRadius: context.radii.cardAll,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF2C3A44), Color(0xFF16202A)],
        ),
      ),
      alignment: Alignment.bottomCenter,
      padding: EdgeInsets.only(bottom: spacing.lg),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.sm,
          vertical: spacing.xs,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: backgroundOpacity),
          borderRadius: BorderRadius.circular(context.radii.field),
        ),
        child: Text(
          'The tide turns at midnight.',
          style: TextStyle(
            color: colour,
            fontSize: 15 * textScale,
            fontFamily: font,
          ),
        ),
      ),
    );
  }
}

/// The name of a font installed on the computer, typed. Its own widget so the
/// controller outlives the dialog's closing animation.
class _FontNameDialog extends StatefulWidget {
  const _FontNameDialog({this.initial});

  final String? initial;

  @override
  State<_FontNameDialog> createState() => _FontNameDialogState();
}

class _FontNameDialogState extends State<_FontNameDialog> {
  late final _name = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_name.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.fontOther),
      content: TextField(
        controller: _name,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: l10n.fontFamilyName,
          helperText: l10n.fontFamilyNameHint,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.actionSave)),
      ],
    );
  }
}

/// A chosen language, or a chosen *absence* of one.
///
/// The sheet returns null when it is dismissed, so "no preference" needs a
/// value of its own to be distinguishable from not answering.
class _LanguageChoice {
  const _LanguageChoice(this.code);

  final String? code;
}

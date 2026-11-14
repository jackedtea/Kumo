// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/appearance_settings.dart';
import '../../app/tokens.dart';
import '../../l10n/app_localizations.dart';
import 'settings_widgets.dart';

/// Screen 1m, Appearance.
///
/// Every control writes straight through to [appearanceSettingsProvider],
/// which persists it and which the app root themes from — so a choice takes
/// effect on the page that made it, with no apply step.
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spacing = context.spacing;
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(appearanceSettingsProvider);
    final controller = ref.read(appearanceSettingsProvider.notifier);

    return SettingsScaffold(
      title: l10n.settingsAppearance,
      children: <Widget>[
        SettingsSection(title: l10n.theme),
        SizedBox(
          height: 108,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: spacing.screenPadding(context.windowSize),
            children: <Widget>[
              for (final (ThemeMode mode, String label) in <(ThemeMode, String)>[
                (ThemeMode.light, l10n.themeLight),
                (ThemeMode.dark, l10n.themeDark),
                (ThemeMode.system, l10n.themeSystem),
              ])
                Padding(
                  padding: EdgeInsets.only(right: spacing.md),
                  child: _ThemeCard(
                    label: label,
                    mode: mode,
                    selected: settings.mode == mode,
                    onTap: () =>
                        controller.update(settings.copyWith(mode: mode)),
                  ),
                ),
            ],
          ),
        ),
        SettingsSection(title: l10n.accent),
        Padding(
          padding: spacing.screenPadding(context.windowSize),
          child: Wrap(
            spacing: spacing.md,
            runSpacing: spacing.md,
            children: <Widget>[
              for (final (int i, Color colour) in accentPresets.indexed)
                _AccentSwatch(
                  colour: colour,
                  selected: i == settings.accentIndex && !settings.dynamicColour,
                  // Picking a colour is also how the user turns the wallpaper
                  // palette back off — the two are one choice in the design.
                  onTap: () => controller.update(
                    settings.copyWith(accentIndex: i, dynamicColour: false),
                  ),
                ),
              _WallpaperSwatch(
                selected: settings.dynamicColour,
                onTap: () =>
                    controller.update(settings.copyWith(dynamicColour: true)),
              ),
            ],
          ),
        ),
        SizedBox(height: spacing.sm),
        SettingsSwitchRow(
          title: l10n.dynamicColour,
          subtitle: l10n.dynamicColourSub,
          value: settings.dynamicColour,
          onChanged: (v) =>
              controller.update(settings.copyWith(dynamicColour: v)),
        ),
        SettingsSwitchRow(
          title: l10n.pureBlack,
          subtitle: l10n.pureBlackSub,
          value: settings.pureBlack,
          onChanged: (v) => controller.update(settings.copyWith(pureBlack: v)),
        ),
        // No Layout section: "Default library view" and "Density" were rows
        // that did nothing but say so. A library's grid or list is chosen on
        // the library itself (View options) and kept on the server.
      ],
    );
  }
}

/// 88h preview card. The swatch shows what the choice looks like rather than
/// relying on the word alone.
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.label,
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final ThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;
    final radii = context.radii;

    return InkWell(
      onTap: onTap,
      borderRadius: radii.cardAll,
      child: Container(
        width: 104,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: radii.cardAll,
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: <Widget>[
            Expanded(
              // Outlined, so the light card stands out from a light page.
              child: Container(
                foregroundDecoration: BoxDecoration(
                  borderRadius: radii.chipAll,
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: ClipRRect(
                  borderRadius: radii.chipAll,
                  child: _Preview(mode: mode),
                ),
              ),
            ),
            SizedBox(height: context.spacing.xs),
            Text(
              label,
              style: context.texts.bodySmall?.copyWith(
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A screen in miniature: an app bar, a row of posters in the accent and two
/// lines of text, in the light or dark palette — or both side by side for
/// "follow the system".
///
/// Every part has a size of its own. The first version was bare
/// `ColoredBox`es, which with no child shrink to nothing, so all three cards
/// drew empty.
class _Preview extends StatelessWidget {
  const _Preview({required this.mode});

  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    final accent = context.colors.primary;

    if (mode == ThemeMode.system) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: _MiniScreen(palette: _Palette.light, accent: accent)),
          Expanded(child: _MiniScreen(palette: _Palette.dark, accent: accent)),
        ],
      );
    }
    return _MiniScreen(
      palette: mode == ThemeMode.light ? _Palette.light : _Palette.dark,
      accent: accent,
    );
  }
}

/// The few colours a miniature screen needs. Fixed rather than read from the
/// theme: the card for Dark has to look dark while the app is light.
enum _Palette {
  light(Color(0xFFF6FAFE), Color(0xFFDDE3EA), Color(0xFFC4CAD1)),
  dark(Color(0xFF0F1417), Color(0xFF2A3136), Color(0xFF3F484E));

  const _Palette(this.background, this.bar, this.line);

  final Color background;
  final Color bar;
  final Color line;
}

class _MiniScreen extends StatelessWidget {
  const _MiniScreen({required this.palette, required this.accent});

  final _Palette palette;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    Widget block(Color colour, {double? width, double height = 6}) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(2),
          ),
        );

    return ColoredBox(
      color: palette.background,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              block(palette.bar, height: 8, width: double.infinity),
              const SizedBox(height: 6),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: block(accent)),
                    const SizedBox(width: 4),
                    Expanded(child: block(accent.withValues(alpha: 0.55))),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              block(palette.line, width: double.infinity, height: 4),
              const SizedBox(height: 3),
              FractionallySizedBox(
                widthFactor: 0.6,
                child: block(palette.line, height: 4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.colour,
    required this.selected,
    required this.onTap,
  });

  final Color colour;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
        child: selected
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 22)
            : null,
      ),
    );
  }
}

class _WallpaperSwatch extends StatelessWidget {
  const _WallpaperSwatch({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colors;

    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline),
        ),
        child: Icon(
          selected ? Icons.check_rounded : Icons.wallpaper_rounded,
          size: 22,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

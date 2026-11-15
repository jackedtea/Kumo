// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/tokens.dart';
import '../../l10n/app_localizations.dart';

/// Scaffold shared by every settings sub-page, so they cannot drift apart.
class SettingsScaffold extends StatelessWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
        title: Text(title),
      ),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: context.spacing.xl + context.systemBottomInset,
        ),
        children: children,
      ),
    );
  }
}

/// Group label in primary, above a run of related rows.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        spacing.screenHorizontal(context.windowSize),
        spacing.xl,
        spacing.screenHorizontal(context.windowSize),
        spacing.sm,
      ),
      child: Text(
        title,
        style: context.texts.titleSmall?.copyWith(color: context.colors.primary),
      ),
    );
  }
}

/// An explanatory paragraph under a row.
///
/// For the settings whose consequence is not visible from the switch itself —
/// passthrough with no receiver attached plays silence, and a user cannot
/// work that out from inside a film.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        spacing.screenHorizontal(context.windowSize),
        0,
        spacing.screenHorizontal(context.windowSize),
        spacing.sm,
      ),
      child: Text(
        text,
        style: context.texts.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A row whose value opens a picker. Value sits on the right, muted.
class SettingsValueRow extends StatelessWidget {
  const SettingsValueRow({
    super.key,
    required this.title,
    required this.value,
    this.subtitle,
    this.onTap,
    this.onServer = false,
  });

  final String title;
  final String value;
  final String? subtitle;
  final VoidCallback? onTap;

  /// Draws [ServerMark] after the title.
  final bool onServer;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: context.spacing.screenPadding(context.windowSize),
      title: SettingsTitle(title, onServer: onServer),
      subtitle: subtitle == null ? null : Text(subtitle!),
      // Bounded, and ellipsised inside that bound. A ListTile asserts when
      // its trailing widget claims the whole tile, and a value long enough to
      // do that is real — an OS version string on a phone, say. Half the
      // width leaves the title readable, which is what tells the user which
      // row they are looking at.
      trailing: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width / 2,
        ),
        child: Text(
          value,
          textAlign: TextAlign.end,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ),
      // No action means a value to read, not a control: nothing happens
      // on a tap, rather than a snackbar saying so.
      onTap: onTap,
    );
  }
}

/// A row that toggles. Uses [SwitchListTile] rather than a hand-rolled switch.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.onServer = false,
  });

  final String title;
  final bool value;
  /// Null greys the row out, for a switch that depends on another.
  final ValueChanged<bool>? onChanged;
  final String? subtitle;

  /// Draws [ServerMark] after the title.
  final bool onServer;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: context.spacing.screenPadding(context.windowSize),
      title: SettingsTitle(title, onServer: onServer),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Labelled slider row — streaming caps, subtitle size, background opacity.
class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
  });

  final String title;
  final String valueLabel;
  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;
    final padding = spacing.screenHorizontal(context.windowSize);

    return Padding(
      padding: EdgeInsets.fromLTRB(padding, spacing.sm, padding, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(title, style: context.texts.bodyLarge)),
              Text(
                valueLabel,
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}


/// The cloud drawn after a setting the server account keeps.
///
/// Most settings belong to the device — its decoder, its speakers, its
/// screen — and a few belong to the account and follow it to every device.
/// Nothing on a row says which, so this does; [ServerMarkLegend] says what it
/// means once per page.
class ServerMark extends StatelessWidget {
  const ServerMark({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context).savedOnServer;

    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: Icon(
          Icons.cloud_outlined,
          size: size,
          color: context.colors.primary,
        ),
      ),
    );
  }
}

/// A row title, with [ServerMark] after it when [onServer].
///
/// The mark is part of the text run, so a title that wraps carries it at the
/// end of its last line rather than pushing it to a column of its own.
class SettingsTitle extends StatelessWidget {
  const SettingsTitle(this.title, {super.key, this.onServer = false});

  final String title;
  final bool onServer;

  @override
  Widget build(BuildContext context) {
    if (!onServer) return Text(title);

    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(text: title),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: EdgeInsetsDirectional.only(start: context.spacing.sm),
              child: const ServerMark(),
            ),
          ),
        ],
      ),
    );
  }
}

/// What [ServerMark] means, at the foot of a page that uses it.
class ServerMarkLegend extends StatelessWidget {
  const ServerMarkLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final spacing = context.spacing;
    final horizontal = spacing.screenHorizontal(context.windowSize);

    return Padding(
      padding: EdgeInsets.fromLTRB(horizontal, spacing.lg, horizontal, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Excluded: the sentence beside it already says it.
          const ExcludeSemantics(child: ServerMark()),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              AppLocalizations.of(context).savedOnServerLegend,
              style: context.texts.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

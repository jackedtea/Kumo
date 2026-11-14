// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

/// One server, several ways to reach it: the LAN address at home, a public
/// one outside. Which is tried, and which wins, is decided here.
library;

import 'dart:async';

import 'server_profile.dart';

/// How long an address gets to answer before the next is preferred. Short on
/// purpose: a LAN address seen from outside does not refuse, it just never
/// answers, and the whole launch waits on it.
const addressProbeTimeout = Duration(seconds: 3);

/// The first of [candidates] that [answers], or null when none does within
/// [timeout].
///
/// All are asked at once and the fastest wins, rather than one after another:
/// the address that answers first is also the one that will serve the
/// library fastest, and asking in turn would make the outside address pay
/// for the home one's silence on every launch away from home.
Future<String?> firstReachable(
  List<String> candidates,
  Future<bool> Function(String address) answers, {
  Duration timeout = addressProbeTimeout,
}) {
  if (candidates.isEmpty) return Future<String?>.value();

  final done = Completer<String?>();
  var pending = candidates.length;

  void settle() {
    if (--pending == 0 && !done.isCompleted) done.complete(null);
  }

  for (final String address in candidates) {
    answers(address).timeout(timeout, onTimeout: () => false).then(
      (ok) {
        if (ok && !done.isCompleted) done.complete(address);
        settle();
      },
      onError: (Object _) => settle(),
    );
  }
  return done.future;
}

/// [extra] cleaned up for storing beside [primary]: normalised, without
/// [primary] itself, without repeats, with [discovered] (the address the
/// server says it has on its own network) added when it is new.
List<String> mergeAddresses(
  String primary,
  Iterable<String> extra, {
  String? discovered,
}) {
  final seen = <String>{primary};
  final merged = <String>[];
  for (final String raw in <String>[...extra, ?discovered]) {
    final url = normaliseServerUrl(raw);
    if (url == null || !seen.add(url)) continue;
    merged.add(url);
  }
  return merged;
}

/// The addresses typed into the edit sheet: one per line, or separated by
/// commas or spaces. Anything that is not an address is left out.
List<String> parseAddressList(String text) => <String>[
      for (final String part in text.split(RegExp(r'[\s,;]+')))
        if (normaliseServerUrl(part) case final String url) url,
    ];

// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:kumo/servers/server_addresses.dart';
import 'package:kumo/servers/server_profile.dart';

const _lan = 'http://192.168.1.20:8096';
const _wan = 'https://media.example.com';

void main() {
  group('firstReachable', () {
    test('the fastest to answer wins, whatever its place', () async {
      final winner = await firstReachable(
        <String>[_lan, _wan],
        (address) async {
          // The LAN address seen from outside: silent, not refused.
          if (address == _lan) return Completer<bool>().future;
          return true;
        },
        timeout: const Duration(milliseconds: 200),
      );
      expect(winner, _wan);
    });

    test('null when none answers in time', () async {
      final winner = await firstReachable(
        <String>[_lan, _wan],
        (_) => Completer<bool>().future,
        timeout: const Duration(milliseconds: 50),
      );
      expect(winner, isNull);
    });

    test('a refusal or a failure is not an answer', () async {
      final winner = await firstReachable(
        <String>[_lan, _wan],
        (address) async {
          if (address == _lan) throw StateError('connection refused');
          return false;
        },
        timeout: const Duration(milliseconds: 50),
      );
      expect(winner, isNull);
    });

    test('nothing to try is nothing found', () async {
      expect(await firstReachable(const <String>[], (_) async => true), isNull);
    });
  });

  group('mergeAddresses', () {
    test('normalises, drops the main one and repeats', () {
      expect(
        mergeAddresses(_wan, <String>[
          '192.168.1.20:8096/',
          _lan,
          '$_wan/',
          'not an address at all ://',
        ]),
        <String>[_lan],
      );
    });

    test('adds what the server says its LAN address is, once', () {
      expect(
        mergeAddresses(_wan, const <String>[], discovered: _lan),
        <String>[_lan],
      );
      expect(
        mergeAddresses(_wan, const <String>[_lan], discovered: _lan),
        <String>[_lan],
      );
      expect(mergeAddresses(_wan, const <String>[], discovered: _wan), isEmpty);
    });
  });

  test('the edit sheet takes one per line, commas or spaces', () {
    expect(
      parseAddressList('$_lan\n\n$_wan, 10.0.0.5:8096  junk://'),
      <String>[_lan, _wan, 'http://10.0.0.5:8096'],
    );
  });

  group('a profile with more than one address', () {
    test('keeps them through storage and tries the main one first', () {
      const profile = ServerProfile(
        id: 'p1',
        name: 'Home',
        uri: _wan,
        userId: 'u1',
        username: 'nam',
        addresses: <String>[_lan],
      );

      final restored = ServerProfile.fromJson(profile.toJson());
      expect(restored.addresses, <String>[_lan]);
      expect(restored.candidateAddresses, <String>[_wan, _lan]);
    });

    test('a profile saved before there were addresses has none', () {
      final old = ServerProfile.fromJson(<String, dynamic>{
        'id': 'p1',
        'uri': _wan,
      });
      expect(old.addresses, isEmpty);
      expect(old.candidateAddresses, <String>[_wan]);
    });
  });
}

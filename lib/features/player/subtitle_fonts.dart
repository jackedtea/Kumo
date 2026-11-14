// This file is part of Kumo.
// Copyright (C) 2026 Nam <namicedtea@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file at the app root for the full notice.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A typeface the subtitle renderer can always find, because the app carries
/// it.
@immutable
class BundledSubtitleFont {
  const BundledSubtitleFont(this.family, this.asset, {this.license});

  /// The name libass matches `sub-font` against — the font's own family name,
  /// not a label of ours.
  final String family;

  final String asset;

  /// Its OFL notice, for the licences page. Null for Roboto, which the app
  /// already registers as its UI face.
  final String? license;
}

/// Every one of them covers Vietnamese in full. A face missing a few marks
/// (ư, ệ…) would have libass borrow those glyphs from another font, and a
/// line drawn in two typefaces looks broken.
const bundledSubtitleFonts = <BundledSubtitleFont>[
  BundledSubtitleFont('Roboto', 'assets/fonts/Roboto-Variable.ttf'),
  BundledSubtitleFont(
    'Noto Sans',
    'assets/fonts/subtitles/NotoSans-Variable.ttf',
    license: 'assets/fonts/subtitles/OFL-NotoSans.txt',
  ),
  BundledSubtitleFont(
    'Be Vietnam Pro',
    'assets/fonts/subtitles/BeVietnamPro-Medium.ttf',
    license: 'assets/fonts/subtitles/OFL-BeVietnamPro.txt',
  ),
  BundledSubtitleFont(
    'Lora',
    'assets/fonts/subtitles/Lora-Variable.ttf',
    license: 'assets/fonts/subtitles/OFL-Lora.txt',
  ),
];

/// The face subtitles use when nothing else was chosen.
const defaultSubtitleFont = 'Roboto';

/// Whether [family] is one the app carries, rather than a name typed for a
/// font installed on the computer.
bool isBundledSubtitleFont(String family) =>
    bundledSubtitleFonts.any((f) => f.family == family);

/// Copies the bundled fonts to a folder libmpv can read, and returns it.
///
/// libass cannot read Flutter assets, and on Android it cannot see the
/// system's fonts either — so mpv's `sub-fonts-dir` points here, on every
/// platform alike. A file already there at the right size is left alone, so
/// this is a few `stat`s on every launch after the first.
Future<String?> prepareSubtitleFontsDir() async {
  try {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'subtitle-fonts'));
    await dir.create(recursive: true);

    for (final BundledSubtitleFont font in bundledSubtitleFonts) {
      final data = await rootBundle.load(font.asset);
      final file = File(p.join(dir.path, p.basename(font.asset)));
      if (await file.exists() && await file.length() == data.lengthInBytes) {
        continue;
      }
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return dir.path;
  } catch (e) {
    // The subtitles still draw, in whatever libass finds on its own.
    debugPrint('Could not prepare the subtitle fonts: $e');
    return null;
  }
}

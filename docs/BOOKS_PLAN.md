# Books — Implementation Plan

> Status (2026-11-16): **B1, B2 and most of B3 are built**, none of it tried
> on a device or against a real server yet — step 0's script
> (`tool/book_position_spike.dart`) has only run against a stand-in. Built:
> the item kinds and position codec, the books library's tabs, the book
> screen, the file cache, the EPUB (foliate-js), PDF (pdfrx) and CBZ/CBT
> readers (EPUB in `webview_flutter`, not `flutter_inappwebview`: see
> CLAUDE.md › Books — so Windows hands EPUBs to the system, like Linux),
> audiobooks through the music player, Home's Continue reading row,
> Books and Audiobooks in Search, and downloaded books opening in the reader
> offline. **Not built:** speed and a chapter list on Now playing for
> audiobooks, ±30 s skips, a multi-file audiobook queued as one book, the
> book cache's line in Settings, and everything under "Later". "Where the
> app stands today" describes the app before step 1; `../CLAUDE.md` › Books
> describes the code as it is.

## Where the app stands today

A Jellyfin **books** library (`CollectionType: books`) is listed by
`/UserViews` and gets an icon (`server_library.dart` → `menu_book_rounded`;
the admin pages can create one). Nothing else works:

| Place | What it does to books now |
|---|---|
| `JellyfinSource.items` | `includeItemTypes=Movie,Series,Video,BoxSet` — a books library opens as an **empty grid** |
| `ServerItemKind` / `_kindFrom` | No `Book`, no `AudioBook`: both map to `unknown` |
| `openServerItem` | An unknown kind falls through to `/library/movie` |
| `_LibraryTab.forKind` | Movies/Shows tabs or the music set; nothing for `books` |
| `resumable` | `/UserItems/Resume?mediaTypes=Video` — a half-read book never appears |
| `PlaybackQueue.kind` | `single · series · music`; a song always starts at zero, which is wrong for an audiobook |
| Player | Nothing renders text, pages or images |

What carries over untouched: the downloads engine (original file, `Range`
resume, `index.json`, offline copies), favourites, `/UserPlayedItems`,
collections and playlists, the filter sheet (genres, tags, years),
`AudioSession` + mini player + Now playing for the audiobook half, and the
server-side settings `MinAudiobookResume` / `MaxAudiobookResume` that the
admin Playback page already edits.

## What the server actually offers (checked against source, 2026-11-14)

- **Item types.** A books library holds `Book` (`MediaType: Book`) and
  `AudioBook` (`MediaType: Audio`, has `RunTimeTicks` and chapters). `Book`
  implements `IHasSeries` (`SeriesName`, `IndexNumber` = volume) and
  `SupportsPeople` (authors arrive in `People`).
- **There is no reading endpoint.** jellyfin-web's three readers (epub.js,
  pdf.js, a libarchive.js comic reader) all fetch the whole file from
  `/Items/{id}/Download` and render it in the browser. So **reading a book
  requires `EnableContentDownloading`** on the account, exactly like Kumo's
  Downloads — and a 403 is a sentence, not a fallback.
- **Formats the web reader takes:** `.epub` (bookPlayer), `.pdf`
  (pdfPlayer), `.cbz .cbr .cbt .cb7` (comicsPlayer). Jellyfin also *lists*
  `.mobi .azw .azw3 .fb2 .txt …` that the web cannot open.
- **How the web stores a position** (playbackmanager: ticks =
  `currentTime() × 10 000`):
  - EPUB: `currentTime = fraction × 1000` → **ticks = fraction × 10 000 000**
    (resume: `ticks / 1e7` → `cfiFromPercentage`).
  - PDF and comics: `currentTime = 0-based page index` → **ticks = page × 10 000**
    (resume: `ticks / 1e4`).
  Kumo must write and read the same encoding, or a book left on the web
  opens on page one in Kumo and the other way round.
- **The trap: `UpdatePlayState` with no runtime.** A `Book` has no
  `RunTimeTicks`, and `UserDataManager.UpdatePlayState` ends in
  `else if (!hasRuntime) { Played = true; position = 0 }`. Both
  `/Sessions/Playing/Progress` and `/Sessions/Playing/Stopped` go through it.
  So **a book must never be reported as a play session** — the first progress
  report would mark it read and throw the position away.
  Write the position directly instead: `POST /UserItems/{id}/UserData`
  (`UpdateUserItemDataDto`: `PlaybackPositionTicks`, `Played`,
  `LastPlayedDate`), which is the plain setter: in the server source that
  overload of `SaveUserData` copies each field the body carries and never
  calls `UpdatePlayState`. **Step 0 verifies this on a real server before
  anything is built on it** — `dart tool/book_position_spike.dart` (its
  header says how), which writes 50 %, reads it back, looks for the book in
  `/UserItems/Resume?mediaTypes=Book`, with `--trap` sends the session
  report to watch it destroy the position, and puts the book back as it was.

## Decisions to take up front

1. **A reader is not the player.** Text and pages have nothing in common
   with `PlaybackController` (no decoder, no queue, no session). A new
   `features/books/` owns a `/reader` route; it borrows nothing from
   `features/player/` except the fullscreen and keep-screen-on helpers.
   Audiobooks are the exception and go the other way: they *are* audio and
   use `AudioSession` (decision 6).
2. **One engine per format family, each picked for reach:**

   | Format | Engine | Platforms |
   |---|---|---|
   | EPUB, MOBI/AZW3, FB2 | **foliate-js** bundled as an asset, in `flutter_inappwebview` | Android, iOS, macOS, Windows (WebView2) |
   | PDF | **pdfrx** (PDFium) | all five |
   | CBZ, CBT | **`archive`** (already in the lock file, transitive) + Flutter `Image` pages | all five |
   | CBR (RAR), CB7 | none in pure Dart | "Open in another app" |

   foliate-js over epub.js: one engine for four formats, real pagination,
   CFI, and it is what current readers ship. The page talks to Dart through
   `addJavaScriptHandler` (relocate → fraction + TOC item; Dart → `goTo`,
   `next`, `prev`, theme, font size).
3. **Where there is no WebView** — Linux (`flutter_inappwebview` has no
   Linux), or Windows without the WebView2 runtime (Windows 10 LTSC does
   not ship it; `WebViewEnvironment.getAvailableVersion()` says null) — an
   EPUB is **downloaded and handed to the system** (`url_launcher` on the
   file). PDF and comics still open in Kumo. Said in a sentence on the
   detail screen, not discovered by a blank page.
4. **Opening = having the file.** Every engine above needs the whole file
   (a zip's central directory is at its end; foliate reads the archive). So
   the reader always works from disk: a downloaded copy if there is one,
   else the downloads engine fetches into `<cache>/books/<profile>/<item>/`
   (same `Range` resume, no token in any index), evicted oldest-first past
   a fixed budget. "Download" on the detail screen moves it into the real
   downloads folder; offline reading then needs nothing new.
5. **Position on the server, in the web's encoding** (memory: prefer server
   storage). `BookPosition` is pure: `{fraction}` for reflowable,
   `{pageIndex, pageCount}` for paged, with `toTicks` / `fromTicks` tested
   against the numbers above. Written via `UserData` debounced (≈5 s after
   the last page turn, and on leaving), `Played = true` only from an
   explicit "Mark as read" or reaching the last page. Offline writes go to
   the existing `pending_reports.json` path as "latest per item", sent when
   the session returns. **No local position store.** A precise CFI is not
   kept: `fraction × 1e7` already resolves to well under a page.
6. **Audiobooks are audio with a memory.** `PlaybackQueue.kind` gains
   `audiobook`: resumes from the server's position (a song never does),
   reports through the normal session (it *has* a runtime, so the server's
   audiobook branch with `MinAudiobookResume`/`MaxAudiobookResume` applies),
   no gapless, playback speed and the sleep timer on Now playing, chapters
   as a list. A multi-file book (a folder of `AudioBook` items) queues the
   folder in `IndexNumber`/`SortName` order.

## Phases

### B1 — A books library that is not empty, and EPUB reading

Data layer (`lib/servers/`):
- `ServerItemKind`: `book`, `audioBook`; `isBook` getter. `_kindFrom` maps
  `Book` / `AudioBook`.
- `ServerItem`: `authors` (from `People` where `Type == Author`, else
  `AlbumArtist` for audiobooks), `bookFormat` (from
  `MediaSources[0].Container`, else the `Path` extension), reuse
  `seriesTitle` + `episodeNumber` as series + volume.
- `MediaLibrarySource.items` takes the library kind: `books` →
  `includeItemTypes=Book,AudioBook`, `recursive=true`.
- `resumable(mediaTypes:)` — `Book` for the reading shelf.
- `setBookPosition(itemId, ticks, {played})` → `POST /UserItems/{id}/UserData`.
- Tests: DTO parsing from captured `Book` / `AudioBook` JSON; the tick codec.

Screens (`lib/features/books/`):
- **Library tabs** for `books`: **Books · Continue reading · Series ·
  Favourites · Collections**. Portrait 2:3 covers (the film grid's tile
  already is). Sort & filter: title, author, date added, year; genres/tags;
  read/unread. Each empty tab says what is missing.
- **Book detail** (`/library/book`): cover, title, authors, series · volume
  (tappable → the series' books, `?browse=bookSeries`), year, publisher,
  overview, format badge, progress ("42 %" / "page 120 of 300"). Read /
  Continue pinned at the foot on a phone (`ItemPrimaryActionBar`);
  favourite, mark read, download through `ItemActionIcons`. The "cannot open
  here" sentence from decision 3 sits where Read would.
- `openServerItem` routes `book` → `/library/book`, `audioBook` → the same
  screen with Play instead of Read.
- **Reader** (`/reader`, above the shell like `/player`): foliate page,
  paginated by default with a scrolled mode; tap zones and swipe;
  arrow / PageUp / PageDown / space and the TV remote's d-pad turn pages;
  a chrome that hides (title, TOC sheet, progress slider with chapter name,
  settings sheet: font size, line height, margins, font, light / sepia /
  dark following the app theme). Keep screen on, fullscreen, back saves the
  position. Reader settings are device-local UI choices in
  `shared_preferences`.

Tests: `screens_test.dart` covers `/library/book` and `/reader` at all three
breakpoints (the reader with a fake engine — no WebView in widget tests),
`l10n_test` (new keys in both ARBs, `l10n_untranslated.json` stays `{}`).

### B2 — PDF and comics

- **PDF** through `pdfrx`: `PdfViewer.file` from the cached copy,
  `initialPageNumber` from the tick codec, `onPageChanged` → position.
  Fit width / fit page, zoom, single page vs continuous, page jump.
- **Comics** (CBZ/CBT): `archive` lists the entries, image entries sorted
  naturally ("2.jpg" before "10.jpg"), decoded lazily one or two pages
  ahead and evicted behind; never all pages in memory. `PageView` with
  pinch zoom; **right-to-left** switch (manga), **two pages side by side**
  past 840dp in landscape. Per-book RTL is stored like Group by collection:
  the server's `DisplayPreferences` for this client.
- CBR / CB7: the system-app hand-off from decision 3.

### B3 — Audiobooks, home, search

- `PlaybackQueue.kind = audiobook` (decision 6) and the Now playing changes:
  speed (0.5–3×, one device-local value, not per book), chapter list, ±30 s / ±10 s skip buttons in place of prev/next track, cover from
  the book.
- **Home**: a "Continue reading" row (`resumable` with `mediaTypes=Book`)
  that also takes half-heard audiobooks (`mediaTypes=Book,Audio`
  narrowed to `AudioBook`, since a song never resumes); "Recently
  added in <books library>" with portrait covers, still honouring
  `LatestItemsExcludes`.
- **Search**: a Books section in `kind_sections.dart`.
- **Downloads tab**: books and audiobooks listed with a format badge; "Download
  all" on a book series asks with the count, like a TV series.
- Remote / cast: a book is not castable (said, not hidden behind a dead
  button); an audiobook casts like a song.

### Later, if wanted

- Bookmarks and highlights — the server has nowhere to keep them; a
  `DisplayPreferences` document per book would work but grows without
  bound. Wait for someone to ask.
- In-book search (foliate supports it), dictionary lookup, text-to-speech.
- OPDS feed (Jellyfin's OPDS plugin) — not needed while the API serves files.

## Deliberately out of scope

- Editing book metadata beyond what the admin Items page already does.
- Converting MOBI/AZW to EPUB, or anything that needs a server plugin.
- DRM'd files (Adobe ADEPT, Kindle DRM) — they fail to open with a sentence.
- A local book library — local sources stay removed.

## Risks and open questions

1. **The position write (step 0).** The whole of decision 5 rests on
   `POST /UserItems/{id}/UserData` storing `PlaybackPositionTicks` as given
   for a `Book`. Verify against the user's server (10.10/10.11): write
   `0.5 × 1e7`, read `UserData` back, open the book in jellyfin-web and see
   it land halfway. If it does not hold, fall back to a `DisplayPreferences`
   document (`kumo-books`, `CustomPrefs[itemId] = ticks`) — still on the
   server, but invisible to the web reader.
2. **Accounts without download permission cannot read at all** — the same
   as on the web. The detail screen says so instead of offering Read.
3. **WebView2 on Windows 10**: the runtime may be absent (LTSC); the probe
   must run before the reader route is offered, and the WebView2 user-data
   folder must be under app support, not beside the exe (read-only install
   dir → crash).
4. **WebView inside the TV / d-pad focus model** — the page must not take
   focus and swallow arrow keys; key events are caught in Flutter and
   forwarded. Unverified until tried on an Android TV.
5. **Large comics** (300 MB CBZ): the cache budget must be bigger than the
   largest file or the book evicts itself; and an image decoded at full
   resolution per page will OOM a phone — decode with `cacheWidth` at the
   screen's width.
6. **Multi-file audiobooks** depend on the server's folder grouping, which
   Jellyfin does inconsistently; test with both a single m4b and a folder of
   mp3s.
7. Book covers: Jellyfin extracts EPUB covers itself; a PDF or CBZ may have
   none, so the tile needs a typographic placeholder (title + author), not
   a grey box.

## Suggested order of work (each a reviewable commit on `dev`)

0. Spike: confirm the `UserData` position write and the web's tick encoding
   against a real server. No app code.
1. Item kinds, DTO fields, books listing, `setBookPosition`, tick codec (+ tests).
2. Books library tabs and the book detail screen (+ screens_test).
3. Book file cache over the downloads engine.
4. foliate-js reader for EPUB, with the WebView probe and the system-app
   hand-off.
5. PDF reader (pdfrx).
6. Comic reader (archive, RTL, two-page spread).
7. Audiobook queue kind + Now playing changes.
8. Home row, search section, downloads tab polish.

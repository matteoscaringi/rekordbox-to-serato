# Rekordbox → Serato

A macOS SwiftUI app that copies your rekordbox library into Serato DJ Pro:

| rekordbox | Serato DJ Pro |
|---|---|
| Playlists | Crates |
| Playlist folders | Parent crates (sub-crates nested inside) |
| Hot cues A–H (with name and colour) | Hot cues 1–8, each colour set to the Serato colour that looks closest |
| Memory cues | Free hot cue slots (Serato has no memory cues). Can be turned off. |
| Hot loops / memory loops | Saved loops |
| Beatgrid (constant and variable tempo) | Serato BeatGrid, first marker on a downbeat |
| Tracks | Added to Serato's library (`database V2`) |

## Download & install
Get **Rekordbox-to-Serato-x.y.z.dmg** (or the .zip) from [Releases](../../releases), open it and drag the app to Applications. You need macOS 14 Sonoma or later; it runs natively on Apple Silicon and Intel.

The app is free and not notarized by Apple, so the first time you open it macOS blocks it. Go to **System Settings ▸ Privacy & Security**, scroll down and click **Open Anyway** (on macOS 14 you can also right-click the app ▸ Open). You only need to do this once.

> Quit Serato DJ before syncing, and keep your own backup of your music. The app backs up Serato's database and crates on every sync, but it does write Serato's cue data into your audio files.

## Read-only on the rekordbox side
The app only reads the **rekordbox XML export**. It never opens or changes rekordbox's database (`master.db`).

In rekordbox: **File ▸ Export Collection in xml format**. Re-export it whenever you want to sync again.

## What it writes
* `_Serato_/Subcrates/*.crate`: one crate per playlist or folder, all inside a parent crate (default name **Rekordbox**).
* `_Serato_/database V2`: only **appends** tracks Serato doesn't know yet. Existing entries are never changed.
* **Your audio files**: Serato keeps cues and beatgrids inside the files themselves, the same way Serato does it:
  * MP3 / AIFF / WAV: ID3 `GEOB` frames
  * FLAC: Vorbis comments
  * M4A (AAC/ALAC): `----:com.serato.dj` atoms

  Only the Serato tags change. The audio data and your other tags are left untouched.
* A backup of `database V2`, `Subcrates` and `neworder.pref` is made before every sync. It goes in `~/Music/_Serato_ Backups (Rekordbox Sync)/`.

**Every sync makes Serato match rekordbox.** Each file's Serato cues, loops and beatgrid are compared with rekordbox's, and anything different is overwritten, including changes you made in Serato. Files that already match are left alone. Serato's library entries get title, artist, album, genre, BPM, key and comment from rekordbox; play counts and Serato's own analysis are kept. Crates from a previous sync whose playlist was deleted (or deselected) are removed. Crates you made yourself in Serato are never touched. rekordbox's own files (its Sampler packs and recordings) are never written to.

## Cue colours
Serato can only show 18 hot cue colours, and the colour it shows on screen differs from the value it stores in the file. So each rekordbox colour is compared against the colours Serato *displays*, with the closest one chosen by CIEDE2000 colour difference, weighted towards hue because Serato's colours are darker. The matching stored value is then written to the file. The colour tables come from Mixxx's reverse-engineered Serato palettes. Run `swift run SyncSelfTest --colors` to see how all 16 rekordbox colours map (red → red, orange → orange, green → green, purple → purple, …).

## Same files, no side effects
* **Same audio files.** Crates and Serato's database point at the exact files rekordbox uses (paths from the XML). Nothing is copied or moved. Before writing, each path is matched to its exact spelling on disk (accents, upper/lower case). Otherwise Serato could list a file twice.
* **rekordbox is not affected.** rekordbox keeps cues, beatgrids and analysis in its own database (`~/Library/Pioneer/…`), not in the audio files. The only thing written to files is Serato's own data, which rekordbox ignores. Title, artist, BPM, key, comments, artwork and all other tags are left as they are, and the audio itself stays bit-identical (checked by the self-test).
* **Serato gets rekordbox's metadata.** New tracks are added to Serato's library with rekordbox's title, artist, album, genre, BPM, key and comment.
* **Watch out after syncing.** Serato itself may write BPM and key into the file's standard tags when you analyse tracks in Serato. rekordbox only picks that up if you use "Reload tag" there. To avoid it, don't run Serato's "Set Auto BPM" / key detection on synced tracks, or lock the beatgrids.
* The first time a file needs more room for tags, it is rewritten safely (temp file, then swapped in). The creation date and Finder tags are kept. Later syncs update the file in place.

## Library Viewer
The **Library Viewer** tab has a **rekordbox | Serato DJ** switch at the top:
* the folder/playlist tree (rekordbox) or the crate tree (Serato), plus the collection / all tracks
* the tracks in the selected item, with whether the file exists and whether the *same file* is also in the other library
* for the selected track, its rekordbox cues and beatgrid side by side with the Serato cues and beatgrid stored in the file, so you can check a sync

It only reads; it never writes anything.

## Use
1. Quit Serato DJ. It rewrites its database when it closes; the app refuses to sync while Serato is running.
2. Open the app. It **finds your rekordbox XML automatically**: it checks rekordbox's automatic export (if you turned it on), the XML path in rekordbox's preferences, the usual places (Documents, Desktop, Music, Downloads) and Spotlight, and loads the newest real rekordbox export. You can still pick a file with **Choose…**. A newer export is picked up when you switch back to the app. Check the `_Serato_` folder (default `~/Music/_Serato_`).
   *Tip:* switch on rekordbox's automatic collection XML export so the file is always current. Run `swift run SyncSelfTest --detect` to see what detection finds.
3. Tick the playlists or folders you want.
4. Click **Preview (dry run)** to see what would happen, then **Sync to Serato**.

## Design: Liquid Glass with a classic fallback
On macOS 26 and later the app uses Apple's Liquid Glass design. It follows Apple's guidance: glass is only for the navigation and control layer, never the content.
* Sidebar (playlists or library tree), toolbar and inspector are standard system containers, so the system renders them in glass.
* **Sync to Serato** is the one primary action and gets tinted glass. Other toolbar buttons use the standard glass.
* The sync status floats over the settings as a glass capsule; there's no glass on top of glass.
* Tables, lists and forms stay plain so they're easy to read.

On macOS 14 Sonoma and 15 Sequoia the same layout uses the classic look: translucent materials and bordered buttons. Every glass API is behind an `#available(macOS 26, *)` check and is weakly linked, so the app runs on those versions unchanged. `build-app.sh` records the real SDK version in the app; macOS 26+ needs that to show it in Liquid Glass.

## App icon
A black vinyl record with a white label inside a two-arrow sync ring, on an indigo tile. `swift Icon/make-icon.swift` regenerates everything from shared geometry:
* `Icon/AppIcon.icon`: the **Liquid Glass** icon (Icon Composer format, three layers). Open it in Icon Composer to fine-tune. `build-app.sh` compiles it with Xcode's `actool`; macOS 26+ shows it as glass (light, dark, clear and tinted). macOS 14/15 get Apple's automatically flattened version.
* `Icon/Assets.xcassets/AppIcon.appiconset`: the **classic** icon (Big Sur-era style with depth and soft shadows), with a preview in `Icon/Previews/classic-1024.png`. Builds without Xcode use it. When Xcode is present, Apple's tools don't support a separate icon for older macOS, so it isn't used in that case.

## Build
```bash
./build-app.sh            # → build/Rekordbox to Serato.app
swift run SyncSelfTest     # encoder + file-format self-test
```
Or open `Package.swift` in Xcode and run the `RekordboxToSerato` scheme. Minimum system: macOS 14.

## Notes
* Crates live in the `_Serato_` folder you pick. Tracks on a *different* external drive than that folder are skipped in its crates (Serato stores paths relative to the drive), and the log tells you which. Sync once per drive by choosing that drive's `_Serato_` folder.
* **MP3 timing**: rekordbox and Serato start decoding some MP3s at slightly different points, depending on how the file was encoded. Each MP3 is classified the way Mixxx does it (mp3guessenc) and shifted by the matching amount: no Xing/Info header 0 ms, FFmpeg/no LAME tag +27 ms, broken LAME tag +34 ms, LAME +10 ms. The offsets come from Mixxx's measurements. AIFF, WAV and FLAC need no correction. "Extra MP3 offset" adds a manual fine-tune on top. Check a file with `swift run SyncSelfTest --mp3case <file.mp3>`, or every synced cue against the beat with `swift run SyncSelfTest --inspect <rekordbox.xml>`.
* Unsupported for cues: OGG and other formats (they are still put in crates).

## License
Copyright © 2026 Matteo Scaringi.

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0 or later** (see [LICENSE](LICENSE)). It comes with no warranty.

GPL fits this project because parts of it are based on work from Mixxx (GPL-2.0-or-later). It also keeps every improved version open for the DJ community.

## Credits
* [Mixxx](https://github.com/mixxxdj/mixxx): the reverse-engineered Serato hot cue colour palettes and the rekordbox/Serato MP3 timing measurements (via mp3guessenc).
* [serato-tags](https://github.com/Holzhaus/serato-tags): documentation of Serato's Markers2, BeatGrid and crate formats.

## Disclaimer
Not affiliated with, endorsed by or connected to AlphaTheta / Pioneer DJ (rekordbox) or Serato. rekordbox and Serato are trademarks of their respective owners and are named here only to describe what the app works with.

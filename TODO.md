# TODO

## DJ settings sync (rekordbox → Serato), paused
The code is written but commented out. Search for `TODO(settings-sync)` to find every part:
`Sources/SyncCore/SettingsSync.swift`, `SyncEngine.swift`, `SyncViewModel.swift`, `ContentView.swift`,
`Sources/SyncSelfTest/SettingsTools.swift`, `main.swift` (section 7 and the `--settings-*` modes) and `Preview.swift`.

Done (worked and was tested in v0.1.1-beta.1):
- Master Tempo per deck (`Player0–3_MasterTempo`) → Keylock per deck (`pitch_keylock_deck_A–D`)
- Instant Doubles (`AutoInstantDoubles`) → `playback_instant_doubles_on_load`
- Written via CFPreferences (`com.serato.seratodj`) only while Serato is closed, backed up first

Still to do:
1. Decode the remaining 3 settings with `--settings-snapshot` / `--settings-diff`
   (toggle each one in rekordbox, quit rekordbox, then diff; note what each option was switched from/to):
   - Start from first cue on load: `DeckLoadingStartPosition` → `playback_play_from_first_cue_on_load`
     (maybe also `playback_play_from_start_on_load`)
   - Lock playing deck: `DeckLoadLock` (currently 2) → `playback_lock_playing_deck`
   - Key notation: `KeyStringSetting` (currently 2) → `display_musical_key_format` (Serato's values are unknown too, so toggle it in Serato as well)
2. Add those to `SettingsSync.mappings`, update the tests and README.
3. Uncomment everything marked `TODO(settings-sync)` and restore the README "DJ settings" section (see git history, commit "Sync shared DJ settings from rekordbox to Serato").

// TODO(settings-sync): disabled for now, see TODO.md
/*
import Foundation

/// Copies DJ settings that rekordbox and Serato DJ Pro have in common from rekordbox to Serato.
///
/// rekordbox: `~/Library/Application Support/Pioneer/rekordbox6/rekordbox3.settings` (only read).
/// Serato DJ Pro 5: the `com.serato.seratodj` preferences domain, written through macOS's
/// preferences system (never by editing the plist file), and only while Serato is closed.
///
/// Only settings whose meaning is verified on both sides are synced. Candidates whose rekordbox
/// values aren't decoded yet are listed in `pendingCalibration`.
public enum SettingsSync {
    public static let seratoDomain = "com.serato.seratodj"

    public struct Mapping: Identifiable {
        public let id: String
        public let title: String
        public let rekordboxKey: String
        public let seratoKey: String
        /// Serato's value for this setting when the key isn't in its preferences (its default).
        public let seratoDefault: Int
        /// rekordbox value → Serato value; nil when rekordbox has no (decodable) value.
        public let convert: (String?) -> Int?
    }

    static func bool(_ v: String?) -> Int? {
        switch v { case "1": return 1; case "0": return 0; default: return nil }
    }

    /// Verified mappings.
    public static let mappings: [Mapping] = {
        var m: [Mapping] = []
        for (i, deck) in ["A", "B", "C", "D"].enumerated() {
            m.append(Mapping(id: "keylock\(deck)", title: "Keylock (Master Tempo), deck \(i + 1)",
                             rekordboxKey: "Player\(i)_MasterTempo", seratoKey: "pitch_keylock_deck_\(deck)",
                             seratoDefault: 0, convert: bool))
        }
        m.append(Mapping(id: "instantDoubles", title: "Instant Doubles when loading the same track",
                         rekordboxKey: "AutoInstantDoubles", seratoKey: "playback_instant_doubles_on_load",
                         seratoDefault: 1, convert: bool))
        return m
    }()

    /// Shared settings that are found on both sides but need a one-time check of rekordbox's values.
    public static let pendingCalibration: [(title: String, rekordboxKey: String, seratoKey: String)] = [
        ("Start from the first cue when loading", "DeckLoadingStartPosition", "playback_play_from_first_cue_on_load"),
        ("Lock a playing deck (no loading onto it)", "DeckLoadLock", "playback_lock_playing_deck"),
        ("Key notation (e.g. 8A / Am / 1m)", "KeyStringSetting", "display_musical_key_format"),
    ]

    public struct Change: Identifiable, Equatable {
        public var id: String { seratoKey }
        public let title: String
        public let seratoKey: String
        public let rekordboxValue: String
        public let current: Int
        public let new: Int
        /// false when Serato hasn't stored this setting yet (it uses its default).
        public let isSetInSerato: Bool
        /// Settings Serato hasn't stored yet are always written, so we never rely on an assumed default.
        public var isChange: Bool { !isSetInSerato || current != new }
    }

    /// Serato's current value for a key (its default when not set).
    static func seratoValue(_ prefs: [String: Any], _ key: String, default def: Int) -> Int {
        switch prefs[key] {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? def
        default: return def
        }
    }

    /// What Serato should look like given rekordbox's settings. Includes unchanged rows (`isChange == false`).
    public static func plan(rekordbox: [String: String], serato: [String: Any]) -> [Change] {
        mappings.compactMap { m in
            guard let new = m.convert(rekordbox[m.rekordboxKey]) else { return nil }
            return Change(title: m.title, seratoKey: m.seratoKey, rekordboxValue: rekordbox[m.rekordboxKey] ?? "",
                          current: seratoValue(serato, m.seratoKey, default: m.seratoDefault), new: new,
                          isSetInSerato: serato[m.seratoKey] != nil)
        }
    }

    public static func readSerato(domain: String = seratoDomain) -> [String: Any] {
        (CFPreferencesCopyMultiple(nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any]) ?? [:]
    }

    /// Writes the changed values. Backs up the whole Serato preferences domain to `backupFolder` first.
    public static func apply(_ changes: [Change], domain: String = seratoDomain, backupFolder: URL?) throws {
        let todo = changes.filter(\.isChange)
        guard !todo.isEmpty else { return }
        if let folder = backupFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let all = readSerato(domain: domain)
            let data = try PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0)
            try data.write(to: folder.appendingPathComponent("\(domain).plist"), options: .atomic)
        }
        for c in todo {
            CFPreferencesSetValue(c.seratoKey as CFString, NSNumber(value: c.new), domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw SyncError.io("could not save Serato's settings")
        }
    }
}
*/

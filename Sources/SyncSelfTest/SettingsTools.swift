// Calibration helper for settings sync (read-only):
//   swift run SyncSelfTest --settings-snapshot <file.json>   remember both apps' settings now
//   swift run SyncSelfTest --settings-diff <file.json>       show what changed since the snapshot
import Foundation
import SyncCore

private func currentSettings() -> [String: String] {
    var out: [String: String] = [:]
    for (k, v) in RekordboxSettings.allValues(home: FileManager.default.homeDirectoryForCurrentUser) ?? [:] { out["rekordbox: " + k] = v }
    for (k, v) in SettingsSync.readSerato() where !(v is Data) { out["Serato: " + k] = "\(v)" }
    return out
}

func settingsSnapshot(_ path: String) -> Int32 {
    let s = currentSettings()
    guard let d = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys, .prettyPrinted]),
          (try? d.write(to: URL(fileURLWithPath: path))) != nil else { print("cannot write \(path)"); return 1 }
    print("Saved \(s.count) settings. Now change one setting in rekordbox or Serato, quit that app, then run --settings-diff \(path)")
    return 0
}

func settingsDiff(_ path: String) -> Int32 {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let old = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { print("cannot read \(path)"); return 1 }
    let now = currentSettings()
    let keys = Set(old.keys).union(now.keys).filter { old[$0] != now[$0] }.sorted()
    if keys.isEmpty { print("No settings changed (did the app save them? rekordbox and Serato write settings when they quit).") }
    for k in keys { print("\(k):  \(old[k] ?? "(not set)")  →  \(now[k] ?? "(removed)")") }
    return 0
}

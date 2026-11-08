// `swift run SyncSelfTest --preview`: a dry run with exactly the settings saved by the app
// (same XML, selected playlists and options). Writes nothing.
import Foundation
@testable import SyncCore

func runPreview() -> Int32 {
    guard let d = UserDefaults(suiteName: "local.rekordbox-to-serato") else { return 1 }
    func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    guard let xml = d.url(forKey: "xmlURL") else { print("The app has no rekordbox XML selected."); return 1 }
    let serato = d.url(forKey: "seratoFolder")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/_Serato_")
    print("XML: \(xml.path)\nSerato folder: \(serato.path)")
    let lib: RBLibrary
    do { lib = try RekordboxXMLParser.parse(url: xml) } catch { print("Cannot read XML: \(error)"); return 1 }
    let allIDs = Set(lib.root.allPlaylists.map(\.id))
    let saved = Set(d.stringArray(forKey: "selected:\(xml.path)") ?? [])
    var o = SyncOptions(seratoFolder: serato, selectedPlaylistIDs: saved.isEmpty ? allIDs : saved.intersection(allIDs))
    o.rootCrateName = d.string(forKey: "rootCrateName") ?? "Rekordbox"
    o.writeCrates = bool("writeCrates", true)
    o.removeStaleCrates = bool("removeStaleCrates", true)
    o.addToSeratoDatabase = bool("addToDatabase", true)
    o.writeCues = bool("writeCues", true)
    o.writeBeatgrids = bool("writeGrids", true)
    o.writeCuesAndGrids = o.writeCues || o.writeBeatgrids
    o.lockBeatgrids = bool("lockGrids", false)
    o.tagWholeCollection = bool("tagWholeCollection", false)
    o.autoMP3Timing = bool("autoMP3Timing", true)
    o.mp3OffsetMs = d.double(forKey: "mp3OffsetMs")
    o.conversion.includeLoops = bool("includeLoops", true)
    o.conversion.memoryCues = MemoryCueMode(rawValue: d.string(forKey: "memoryCueMode") ?? "") ?? .fillEmptySlots
    o.dryRun = true
    print("Playlists selected: \(o.selectedPlaylistIDs.count) of \(allIDs.count), parent crate: \"\(o.rootCrateName)\"\n")
    var lines: [SyncLogLine] = []
    do {
        let r = try SyncEngine(library: lib, options: o, progress: { _, _ in }, log: { lines.append($0) }).run()
        let wouldUpdate = lines.filter { $0.message.hasPrefix("Would update cues/beatgrid") }
        let crateLines = lines.filter { $0.message.hasPrefix("Would write crate") }
        let removed = lines.filter { $0.message.hasPrefix("Would remove") }
        let warnings = lines.filter { $0.level == .warning || $0.level == .error }
        for l in lines where !(wouldUpdate + crateLines + warnings).contains(where: { $0.id == l.id }) && l.level != .success {
            print("• \(l.message)")
        }
        print("\nFiles whose Serato cues/beatgrid would change (\(wouldUpdate.count)):")
        for l in wouldUpdate { print("  " + l.message.replacingOccurrences(of: "Would update cues/beatgrid: ", with: "")) }
        // Why each file would change: compare what's in the file with what rekordbox wants.
        let engine = SyncEngine(library: lib, options: o, progress: { _, _ in }, log: { _ in })
        var reasons: [String: Int] = [:]
        var examples: [String: String] = [:]
        for t in lib.tracks.values where FileManager.default.fileExists(atPath: t.path) && AudioTagWriter.supports(t.path) && !SyncEngine.isRekordboxOwned(t.path) {
            guard let cur = try? AudioTagWriter.readSerato(from: URL(fileURLWithPath: t.path)) else { continue }
            let (p, _) = engine.payload(for: t)
            var why: [String] = []
            if let want = p.markers2Raw, cur.markers2 != want {
                let a = SeratoTags.decodeMarkers(cur.markers2 ?? []), b = SeratoTags.decodeMarkers(want)
                if a.cues.map(\.index) != b.cues.map(\.index) || a.loops.count != b.loops.count { why.append("cues added/removed") }
                else {
                    if zip(a.cues, b.cues).contains(where: { abs(Int($0.positionMs) - Int($1.positionMs)) > 1 }) { why.append("cue timing") }
                    if zip(a.cues, b.cues).contains(where: { $0.color != $1.color }) { why.append("cue colours") }
                    if zip(a.cues, b.cues).contains(where: { $0.name != $1.name }) { why.append("cue names") }
                    if a.bpmLock != b.bpmLock { why.append("grid lock") }
                }
            }
            if let want = p.beatGridRaw, cur.beatGrid != want { why.append("beatgrid") }
            guard !why.isEmpty else { continue }
            let key = why.joined(separator: " + ")
            reasons[key, default: 0] += 1
            if examples[key] == nil { examples[key] = "\(t.artist) – \(t.title)" }
        }
        print("\nWhy those files would change:")
        for (k, n) in reasons.sorted(by: { $0.value > $1.value }) { print("  \(n)× \(k)   (e.g. \(examples[k]!))") }

        print("\nCrates that would be written: \(crateLines.count)" + (removed.isEmpty ? "" : ", removed: \(removed.count)"))
        if !warnings.isEmpty {
            print("\nWarnings (\(warnings.count)):")
            for w in warnings.prefix(20) { print("  ⚠︎ " + w.message) }
            if warnings.count > 20 { print("  … and \(warnings.count - 20) more") }
        }
        print("\n" + r.summary)
    } catch { print("Preview failed: \(error.localizedDescription)"); return 1 }
    return 0
}

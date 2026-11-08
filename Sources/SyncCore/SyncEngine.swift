import CryptoKit
import Foundation

public struct SyncOptions {
    public var seratoFolder: URL
    public var selectedPlaylistIDs: Set<String>
    public var rootCrateName = "Rekordbox"
    public var writeCrates = true
    public var removeStaleCrates = true
    public var addToSeratoDatabase = true
    public var writeCuesAndGrids = true
    public var writeBeatgrids = true
    public var writeCues = true
    public var lockBeatgrids = false
    /// true: every track of the collection gets cues/grids; false: only tracks in selected playlists.
    public var tagWholeCollection = false
    /// Correct each MP3 for the rekordbox↔Serato decoder difference (see MP3TimingCase).
    public var autoMP3Timing = true
    /// Extra manual offset for MP3s, on top of the automatic correction.
    public var mp3OffsetMs: Double = 0
    public var backup = true
    public var dryRun = false
    public var conversion = ConversionOptions()

    public init(seratoFolder: URL, selectedPlaylistIDs: Set<String>) {
        self.seratoFolder = seratoFolder; self.selectedPlaylistIDs = selectedPlaylistIDs
    }
}

public struct SyncLogLine: Identifiable {
    public enum Level { case info, warning, error, success }
    public let id = UUID()
    public let level: Level
    public let message: String
    public init(level: Level, message: String) { self.level = level; self.message = message }
}

public struct SyncReport {
    public var cratesWritten = 0
    public var cratesRemoved = 0
    public var tracksAddedToDatabase = 0
    public var tracksUpdatedInDatabase = 0
    public var filesSkippedRekordboxOwned = 0
    public var filesTagged = 0
    public var filesUnchanged = 0
    public var filesMissing = 0
    public var filesFailed = 0
    public var filesUnsupported = 0
    public var backupFolder: URL?

    public var summary: String {
        var s = "Crates written: \(cratesWritten), removed: \(cratesRemoved). Serato library: \(tracksAddedToDatabase) added, \(tracksUpdatedInDatabase) updated. "
        s += "Files updated: \(filesTagged), already up to date: \(filesUnchanged), missing: \(filesMissing), unsupported: \(filesUnsupported), failed: \(filesFailed)."
        if filesSkippedRekordboxOwned > 0 { s += " Left alone (rekordbox's own sampler/recording files): \(filesSkippedRekordboxOwned)." }
        return s
    }
}

/// Remembers which crates this tool wrote, so re-syncs can remove deleted playlists.
struct SyncManifest: Codable {
    var crates: [String] = []
    static let fileName = ".rekordbox-to-serato.json"
}

public struct CratePlanItem {
    public var components: [String]
    public var fileName: String
    public var trackIDs: [String]
}

public final class SyncEngine {
    public typealias Progress = (_ fraction: Double, _ status: String) -> Void
    public typealias Log = (SyncLogLine) -> Void

    var library: RBLibrary
    let options: SyncOptions
    let progress: Progress
    let log: Log
    let isCancelled: () -> Bool
    let fm = FileManager.default
    var mp3Cases: [MP3TimingCase: Int] = [:]

    public init(library: RBLibrary, options: SyncOptions, progress: @escaping Progress,
                log: @escaping Log, isCancelled: @escaping () -> Bool = { false }) {
        self.library = library; self.options = options; self.progress = progress
        self.log = log; self.isCancelled = isCancelled
    }

    func info(_ s: String) { log(SyncLogLine(level: .info, message: s)) }
    func warn(_ s: String) { log(SyncLogLine(level: .warning, message: s)) }
    func fail(_ s: String) { log(SyncLogLine(level: .error, message: s)) }

    public static func cratePlan(library: RBLibrary, selected: Set<String>, rootName: String) -> [CratePlanItem] {
        var items: [CratePlanItem] = []
        var usedNames = Set<String>()
        func add(_ comps: [String], _ ids: [String]) {
            var c = comps
            var name = SeratoCrate.fileName(for: c)
            var n = 2
            while usedNames.contains(name.lowercased()) {
                c[c.count - 1] = "\(comps.last!) (\(n))"; n += 1
                name = SeratoCrate.fileName(for: c)
            }
            usedNames.insert(name.lowercased())
            items.append(CratePlanItem(components: c, fileName: name, trackIDs: ids))
        }
        func hasSelection(_ n: RBNode) -> Bool { n.allPlaylists.contains { selected.contains($0.id) } }
        func walk(_ node: RBNode, _ comps: [String]) {
            for child in node.children {
                let c = comps + [child.name]
                if child.isFolder {
                    guard hasSelection(child) else { continue }
                    add(c, [])
                    walk(child, c)
                } else if selected.contains(child.id) {
                    add(c, child.trackIDs)
                }
            }
        }
        let root = rootName.trimmingCharacters(in: .whitespaces)
        if !root.isEmpty, hasSelection(library.root) { add([root], []) }
        walk(library.root, root.isEmpty ? [] : [root])
        return items
    }

    public func run() throws -> SyncReport {
        var report = SyncReport()
        let serato = options.seratoFolder
        let dry = options.dryRun
        if dry { info("DRY RUN: nothing will be written.") }

        if !fm.fileExists(atPath: serato.path) {
            if dry { info("Would create \(serato.path)") } else {
                try fm.createDirectory(at: serato, withIntermediateDirectories: true)
            }
        }
        let manifestURL = serato.appendingPathComponent(SyncManifest.fileName)
        var manifest = (try? JSONDecoder().decode(SyncManifest.self, from: Data(contentsOf: manifestURL))) ?? SyncManifest()

        let plan = SyncEngine.cratePlan(library: library, selected: options.selectedPlaylistIDs, rootName: options.rootCrateName)
        var trackIDs: [String]
        if options.tagWholeCollection {
            trackIDs = library.trackOrder
        } else {
            var seen = Set<String>()
            trackIDs = plan.flatMap(\.trackIDs).filter { seen.insert($0).inserted }
        }

        // Use the exact file rekordbox uses, spelled exactly as on disk (see OnDiskPathResolver).
        progress(0.01, "Matching files on disk…")
        let resolver = OnDiskPathResolver()
        var respelled = 0
        for id in Set(plan.flatMap(\.trackIDs) + trackIDs) {
            guard let t = library.tracks[id] else { continue }
            let resolved = resolver.resolve(t.path)
            if resolved != t.path { library.tracks[id]?.path = resolved; respelled += 1 }
        }
        if respelled > 0 { info("Matched \(respelled) file paths to their exact spelling on disk (accents/case).") }

        // Backup
        if options.backup && !dry && (options.writeCrates || options.addToSeratoDatabase) {
            report.backupFolder = try backup(serato)
            if let b = report.backupFolder { info("Backed up Serato library to \(b.path)") }
        }

        // Crates
        if options.writeCrates {
            progress(0.02, "Writing crates…")
            let sub = serato.appendingPathComponent("Subcrates")
            if !dry { try fm.createDirectory(at: sub, withIntermediateDirectories: true) }
            var written: [String] = []
            for item in plan {
                var paths: [String] = []
                for id in item.trackIDs {
                    guard let t = library.tracks[id] else { continue }
                    if let p = SeratoCrate.seratoPath(forFile: t.path, seratoFolder: serato) { paths.append(p) } else {
                        warn("“\(t.title)” is on a different drive than the Serato folder; skipped in crate \(item.components.joined(separator: " ▸ "))")
                    }
                }
                if !dry {
                    try Data(SeratoCrate.build(trackPaths: paths)).write(to: sub.appendingPathComponent(item.fileName), options: .atomic)
                }
                written.append(item.fileName)
                report.cratesWritten += 1
                info("\(dry ? "Would write" : "Wrote") crate \(item.components.joined(separator: " ▸ ")) (\(paths.count) tracks)")
            }
            if options.removeStaleCrates {
                for old in Set(manifest.crates).subtracting(written) {
                    let u = sub.appendingPathComponent(old)
                    guard fm.fileExists(atPath: u.path) else { continue }
                    if !dry { try? fm.removeItem(at: u) }
                    report.cratesRemoved += 1
                    info("\(dry ? "Would remove" : "Removed") old crate \(old)")
                }
            }
            manifest.crates = written
        }

        // database V2
        if options.addToSeratoDatabase {
            progress(0.05, "Updating Serato database…")
            let dbURL = serato.appendingPathComponent(SeratoDatabase.fileName)
            let existing = fm.fileExists(atPath: dbURL.path) ? [UInt8](try Data(contentsOf: dbURL)) : nil
            let entries: [(String, RBTrack)] = trackIDs.compactMap { id in
                guard let t = library.tracks[id], let p = SeratoCrate.seratoPath(forFile: t.path, seratoFolder: serato) else { return nil }
                return (p, t)
            }
            let r = SeratoDatabase.upserting(existing, tracks: entries)
            if (r.added > 0 || r.updated > 0) && !dry { try Data(r.bytes).write(to: dbURL, options: .atomic) }
            report.tracksAddedToDatabase = r.added
            report.tracksUpdatedInDatabase = r.updated
            info("\(dry ? "Would add" : "Added") \(r.added) new tracks to Serato's library and \(dry ? "would update" : "updated") \(r.updated) (title, artist, BPM, key… from rekordbox)")
        }

        // Cues & beatgrids
        if options.writeCuesAndGrids {
            let total = max(1, trackIDs.count)
            for (i, id) in trackIDs.enumerated() {
                if isCancelled() { warn("Cancelled by user."); break }
                guard let t = library.tracks[id] else { continue }
                progress(0.08 + 0.92 * Double(i) / Double(total), "Tagging \(i + 1)/\(total): \(t.title)")
                tag(t, report: &report)
            }
            if !mp3Cases.isEmpty {
                let parts = mp3Cases.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.value)× \($0.key.explanation) (+\(Int($0.key.seratoOffsetMs)) ms)" }
                info("MP3 timing corrected per file: " + parts.joined(separator: ", "))
            }
        }

        if !dry {
            if let d = try? JSONEncoder().encode(manifest) { try? d.write(to: manifestURL, options: .atomic) }
        }
        progress(1, dry ? "Dry run finished" : "Sync finished")
        log(SyncLogLine(level: .success, message: report.summary))
        return report
    }

    func payload(for t: RBTrack) -> (SeratoTagPayload, [String]) {
        var conv = options.conversion
        if t.fileExtension == "mp3" {
            var ms = options.mp3OffsetMs
            if options.autoMP3Timing, let c = MP3TimingCase.detect(url: URL(fileURLWithPath: t.path)) {
                ms += c.seratoOffsetMs
                mp3Cases[c, default: 0] += 1
            }
            conv.timeOffset += ms / 1000
        }
        var markers: [UInt8]?
        var warnings: [String] = []
        if options.writeCues {
            let r = Converter.cuesAndLoops(for: t, options: conv)
            warnings = r.warnings
            markers = SeratoTags.markers2Raw(cues: r.cues, loops: r.loops, bpmLock: options.lockBeatgrids)
        }
        var grid: [UInt8]?
        if options.writeBeatgrids {
            let g = Converter.beatGrid(for: t, timeOffset: conv.timeOffset)
            if !g.isEmpty { grid = SeratoTags.beatGridRaw(g) }
        }
        return (SeratoTagPayload(markers2Raw: markers, beatGridRaw: grid), warnings)
    }

    /// rekordbox's own files (Sampler packs, recordings) are never written to.
    static func isRekordboxOwned(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("/rekordbox/sampler/") || p.contains("/rekordbox/recording") || p.contains("/library/pioneer/")
            || p.contains("/pioneer/rekordbox/")
    }

    /// Makes the file's Serato data match rekordbox exactly. Whatever is in the file now
    /// (including cues or grids edited in Serato) is replaced when it differs.
    func tag(_ t: RBTrack, report: inout SyncReport) {
        let name = "\(t.artist.isEmpty ? "" : t.artist + " – ")\(t.title)"
        guard !Self.isRekordboxOwned(t.path) else { report.filesSkippedRekordboxOwned += 1; return }
        guard AudioTagWriter.supports(t.path) else {
            report.filesUnsupported += 1; warn("Unsupported file type, cues not written: \(t.path)"); return
        }
        guard fm.fileExists(atPath: t.path) else {
            report.filesMissing += 1; warn("Missing file: \(t.path)"); return
        }
        let (p, warnings) = payload(for: t)
        for w in warnings { warn("\(name): \(w)") }
        if p.isEmpty { report.filesUnchanged += 1; return }

        let url = URL(fileURLWithPath: t.path)
        if let current = try? AudioTagWriter.readSerato(from: url),
           p.markers2Raw == nil || current.markers2 == p.markers2Raw,
           p.beatGridRaw == nil || current.beatGrid == p.beatGridRaw {
            report.filesUnchanged += 1
            return
        }
        if options.dryRun {
            report.filesTagged += 1
            info("Would update cues/beatgrid: \(name)")
            return
        }
        do {
            try AudioTagWriter.write(p, to: url)
            report.filesTagged += 1
        } catch {
            report.filesFailed += 1
            fail("\(name): \(error.localizedDescription)")
        }
    }

    func backup(_ serato: URL) throws -> URL? {
        let items = ["database V2", "Subcrates", "neworder.pref"].map { serato.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !items.isEmpty else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let parent = serato.deletingLastPathComponent().appendingPathComponent("_Serato_ Backups (Rekordbox Sync)")
        let stamp = f.string(from: Date())
        var dest = parent.appendingPathComponent(stamp)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = parent.appendingPathComponent("\(stamp) (\(n))"); n += 1 }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for i in items { try fm.copyItem(at: i, to: dest.appendingPathComponent(i.lastPathComponent)) }
        return dest
    }
}

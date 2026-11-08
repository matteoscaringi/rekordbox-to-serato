import AppKit
import SwiftUI
import SyncCore

@MainActor
final class SyncViewModel: ObservableObject {
    @Published var xmlURL: URL?
    @Published var library: RBLibrary?
    @Published var seratoFolder: URL
    @Published var selected: Set<String> = []
    @Published var log: [SyncLogLine] = []
    @Published var progress: Double = 0
    @Published var status = "Load your rekordbox XML to begin." { didSet { showStatusBriefly() } }
    @Published var isRunning = false { didSet { showStatusBriefly() } }
    /// The floating status bar shows each message for 10 seconds (and stays while a sync runs).
    @Published private(set) var statusVisible = true
    private var hideStatusTask: Task<Void, Never>?
    @Published var alert: String?
    /// Bumped whenever the rekordbox library or the Serato folder changes or a sync finishes.
    @Published var libraryVersion = 0
    /// Where an automatically found XML came from (nil when the user picked the file).
    @Published var xmlSource: String?
    @Published var isDetecting = false
    /// rekordbox's "automatic collection XML export" setting (nil if rekordbox settings weren't found).
    @Published var rekordboxAutoExportEnabled: Bool?
    private var loadedXMLDate: Date?
    private var xmlChosenManually: Bool {
        get { UserDefaults.standard.bool(forKey: "xmlChosenManually") }
        set { UserDefaults.standard.set(newValue, forKey: "xmlChosenManually") }
    }

    // Options (persisted)
    @AppStorage("rootCrateName") var rootCrateName = "Rekordbox"
    @AppStorage("writeCrates") var writeCrates = true
    @AppStorage("removeStaleCrates") var removeStaleCrates = true
    @AppStorage("addToDatabase") var addToDatabase = true
    @AppStorage("writeCues") var writeCues = true
    @AppStorage("writeGrids") var writeGrids = true
    @AppStorage("lockGrids") var lockGrids = false
    @AppStorage("includeLoops") var includeLoops = true
    @AppStorage("memoryCueMode") var memoryCueMode: MemoryCueMode = .fillEmptySlots
    @AppStorage("tagWholeCollection") var tagWholeCollection = false
    @AppStorage("autoMP3Timing") var autoMP3Timing = true
    @AppStorage("mp3OffsetMs") var mp3OffsetMs = 0.0
    @AppStorage("backup") var backup = true

    private var cancelFlag = CancelFlag()

    init() {
        let d = UserDefaults.standard
        seratoFolder = d.url(forKey: "seratoFolder")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/_Serato_")
        // A path saved before auto-detection existed was picked by hand: keep honouring it.
        if d.object(forKey: "xmlChosenManually") == nil && d.url(forKey: "xmlURL") != nil { xmlChosenManually = true }
        if let x = d.url(forKey: "xmlURL"), FileManager.default.fileExists(atPath: x.path) {
            xmlURL = x
            loadXML()
            if !xmlChosenManually { detectXML(userInitiated: false) }   // maybe there's a newer export now
        } else {
            // Nothing picked yet (or the file is gone): look for the rekordbox export ourselves.
            detectXML(userInitiated: false)
        }
    }

    private func showStatusBriefly() {
        hideStatusTask?.cancel()
        if !statusVisible { statusVisible = true }
        guard !isRunning else { return }
        hideStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.isRunning else { return }
            self.statusVisible = false
        }
    }

    // MARK: Automatic XML detection

    /// Finds the rekordbox XML (rekordbox's own settings, usual locations, Spotlight) and loads it.
    func detectXML(userInitiated: Bool) {
        guard !isDetecting else { return }
        isDetecting = true
        if userInitiated || library == nil { status = "Looking for your rekordbox XML…" }
        Task.detached(priority: .userInitiated) {
            let best = RekordboxXMLLocator.best()
            let settings = RekordboxSettings.read(home: FileManager.default.homeDirectoryForCurrentUser)
            await MainActor.run {
                self.isDetecting = false
                self.rekordboxAutoExportEnabled = settings?.autoExportEnabled
                guard let best else {
                    if self.library == nil {
                        self.status = "No rekordbox XML found yet. Export it from rekordbox (File ▸ Export Collection in xml format)."
                    }
                    if userInitiated {
                        self.alert = "No rekordbox XML was found.\n\nIn rekordbox choose File ▸ Export Collection in xml format (any folder is fine), then click Find Automatically again."
                    }
                    return
                }
                let changed = best.url != self.xmlURL || best.modified != self.loadedXMLDate
                self.xmlURL = best.url
                self.xmlSource = best.source.rawValue
                self.xmlChosenManually = false
                UserDefaults.standard.set(best.url, forKey: "xmlURL")
                if changed || self.library == nil { self.loadXML() }
            }
        }
    }

    /// Called when the app becomes active: picks up a newer export from rekordbox.
    func refreshXMLIfNeeded() {
        guard !isRunning else { return }
        if !xmlChosenManually {
            detectXML(userInitiated: false)
        } else if let url = xmlURL, FileManager.default.fileExists(atPath: url.path),
                  let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  date != loadedXMLDate {
            loadXML()
        }
    }

    var trackCount: Int { library?.tracks.count ?? 0 }
    var selectedTrackCount: Int {
        guard let lib = library else { return 0 }
        var s = Set<String>()
        for p in lib.root.allPlaylists where selected.contains(p.id) { s.formUnion(p.trackIDs) }
        return s.count
    }

    func chooseXML() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.xml]
        p.message = "Choose the XML exported from rekordbox (File ▸ Export Collection in xml format)"
        if p.runModal() == .OK, let u = p.url {
            xmlURL = u
            xmlSource = nil
            xmlChosenManually = true
            UserDefaults.standard.set(u, forKey: "xmlURL")
            loadXML()
        }
    }

    func chooseSeratoFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = seratoFolder.deletingLastPathComponent()
        p.message = "Choose the _Serato_ folder (usually ~/Music/_Serato_)"
        if p.runModal() == .OK, let u = p.url {
            seratoFolder = u
            UserDefaults.standard.set(u, forKey: "seratoFolder")
            libraryVersion += 1
        }
    }

    func loadXML() {
        guard let url = xmlURL else { return }
        status = "Reading \(url.lastPathComponent)…"
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        Task.detached(priority: .userInitiated) {
            do {
                let lib = try RekordboxXMLParser.parse(url: url)
                await MainActor.run {
                    self.library = lib
                    self.loadedXMLDate = date
                    let ids = Set(lib.root.allPlaylists.map(\.id))
                    let saved = Set(UserDefaults.standard.stringArray(forKey: "selected:\(url.path)") ?? [])
                    self.selected = saved.isEmpty ? ids : saved.intersection(ids)
                    self.status = "Loaded \(lib.tracks.count) tracks and \(lib.playlistCount) playlists."
                    self.libraryVersion += 1
                }
            } catch {
                await MainActor.run {
                    self.library = nil
                    self.status = "Could not read XML."
                    self.alert = error.localizedDescription
                }
            }
        }
    }

    // MARK: Selection

    func isSelected(_ n: RBNode) -> Bool {
        n.isFolder ? (!n.allPlaylists.isEmpty && n.allPlaylists.allSatisfy { selected.contains($0.id) }) : selected.contains(n.id)
    }

    func setSelected(_ n: RBNode, _ on: Bool) {
        for p in n.allPlaylists { if on { selected.insert(p.id) } else { selected.remove(p.id) } }
        saveSelection()
    }

    func selectAll(_ on: Bool) {
        guard let lib = library else { return }
        selected = on ? Set(lib.root.allPlaylists.map(\.id)) : []
        saveSelection()
    }

    private func saveSelection() {
        if let x = xmlURL { UserDefaults.standard.set(Array(selected), forKey: "selected:\(x.path)") }
    }

    // MARK: Sync

    static func rekordboxIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { ($0.localizedName ?? "").lowercased().hasPrefix("rekordbox") }
    }

    static func seratoIsRunning() -> Bool {
        // Only Serato's own DJ apps (bundle IDs "com.serato.…"), never this app itself,
        // whose bundle ID also contains the word "serato".
        NSWorkspace.shared.runningApplications.contains {
            guard $0.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            let n = ($0.localizedName ?? "").lowercased()
            let b = ($0.bundleIdentifier ?? "").lowercased()
            return b.hasPrefix("com.serato.") || n.hasPrefix("serato dj")
        }
    }

    func run(dryRun: Bool) {
        guard let lib = library else { return }
        if !dryRun && Self.seratoIsRunning() {
            alert = "Please quit Serato DJ first. Serato rewrites its database and crates when it closes, which would undo the sync."
            return
        }
        var o = SyncOptions(seratoFolder: seratoFolder, selectedPlaylistIDs: selected)
        o.rootCrateName = rootCrateName
        o.writeCrates = writeCrates
        o.removeStaleCrates = removeStaleCrates
        o.addToSeratoDatabase = addToDatabase
        o.writeCues = writeCues
        o.writeBeatgrids = writeGrids
        o.writeCuesAndGrids = writeCues || writeGrids
        o.lockBeatgrids = lockGrids
        o.tagWholeCollection = tagWholeCollection
        o.autoMP3Timing = autoMP3Timing
        o.mp3OffsetMs = mp3OffsetMs
        o.backup = backup
        o.dryRun = dryRun
        o.conversion.includeLoops = includeLoops
        o.conversion.memoryCues = memoryCueMode

        log = []
        if !dryRun && Self.rekordboxIsRunning() && (writeCues || writeGrids) {
            log.append(SyncLogLine(level: .warning, message: "rekordbox is open. That's fine (rekordbox keeps its cues in its own database, not in the files), but don't play tracks in rekordbox while the sync is writing to them."))
        }
        progress = 0
        isRunning = true
        let flag = CancelFlag()
        cancelFlag = flag
        let options = o

        Task.detached(priority: .userInitiated) {
            let engine = SyncEngine(
                library: lib, options: options,
                progress: { f, s in Task { @MainActor in self.progress = f; self.status = s } },
                log: { line in Task { @MainActor in self.log.append(line) } },
                isCancelled: { flag.value })
            do {
                let r = try engine.run()
                await MainActor.run { self.isRunning = false; self.status = r.summary; self.libraryVersion += 1 }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.status = "Sync failed."
                    self.alert = error.localizedDescription
                }
            }
        }
    }

    func cancel() { cancelFlag.value = true }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

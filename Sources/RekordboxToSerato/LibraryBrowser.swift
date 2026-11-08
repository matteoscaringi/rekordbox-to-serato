import SwiftUI
import SyncCore

enum BrowserSource: String, CaseIterable, Identifiable {
    case rekordbox = "rekordbox"
    case serato = "Serato DJ"
    var id: String { rawValue }
}

struct BrowserNode: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    var children: [BrowserNode]?
    let trackKeys: [String]
    static func == (a: BrowserNode, b: BrowserNode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct BrowserTrack: Identifiable {
    let id: String          // unique row id
    let key: String         // rekordbox TrackID or Serato path
    let title: String
    let artist: String
    let bpm: String
    let musicalKey: String
    let path: String
    let exists: Bool
    let inOther: Bool
}

struct CueRow: Identifiable {
    let id = UUID()
    let kind: String
    let slot: String
    let time: String
    let name: String
    let color: RGB?
}

struct TrackDetail {
    var title = ""
    var path = ""
    var rekordboxCues: [CueRow]?
    var rekordboxGrid: String?
    var seratoCues: [CueRow]?
    var seratoGrid: String?
    var seratoNote: String?
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var source: BrowserSource = .rekordbox { didSet { selectedNodeID = rootID; selectedTrackID = nil } }
    @Published var selectedNodeID: String? = "rb-all"
    @Published var selectedTrackID: String? { didSet { loadDetail() } }
    @Published var filter = ""
    @Published private(set) var serato: SeratoLibrary?
    @Published private(set) var seratoError: String?
    @Published var detail: TrackDetail?

    private(set) var rekordbox: RBLibrary?
    private var seratoFolder = URL(fileURLWithPath: "/")
    private var rbByPath: [String: String] = [:]   // NFC path -> TrackID
    private var detailTask: Task<Void, Never>?

    var rootID: String { source == .rekordbox ? "rb-all" : "se-all" }

    var selectedNodeName: String {
        guard let id = selectedNodeID else { return source.rawValue }
        return findNode(id, in: nodes)?.name ?? source.rawValue
    }

    static func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    func reload(rekordbox: RBLibrary?, seratoFolder: URL) {
        self.rekordbox = rekordbox
        self.seratoFolder = seratoFolder
        rbByPath = [:]
        for t in rekordbox?.tracks.values.map({ $0 }) ?? [] { rbByPath[Self.norm(t.path)] = t.id }
        do {
            serato = try SeratoLibraryReader.read(seratoFolder: seratoFolder)
            seratoError = nil
        } catch {
            serato = nil
            seratoError = error.localizedDescription
        }
        if selectedNodeID == nil { selectedNodeID = rootID }
        loadDetail()
    }

    // MARK: Tree

    var nodes: [BrowserNode] {
        switch source {
        case .rekordbox:
            guard let lib = rekordbox else { return [] }
            func map(_ n: RBNode) -> BrowserNode {
                BrowserNode(id: "rb" + n.id, name: n.name, icon: n.isFolder ? "folder" : "music.note.list",
                            children: n.isFolder ? n.children.map(map) : nil, trackKeys: n.trackIDs)
            }
            return [BrowserNode(id: "rb-all", name: "Collection (\(lib.tracks.count))", icon: "music.note.house",
                                children: nil, trackKeys: lib.trackOrder)] + lib.root.children.map(map)
        case .serato:
            guard let lib = serato else { return [] }
            func map(_ n: SeratoCrateNode) -> BrowserNode {
                BrowserNode(id: "se" + n.id, name: n.name, icon: n.hasCrateFile ? "shippingbox" : "folder",
                            children: n.children.isEmpty ? nil : n.children.map(map), trackKeys: n.trackPaths)
            }
            return [BrowserNode(id: "se-all", name: "All tracks (\(lib.tracks.count))", icon: "music.note.house",
                                children: nil, trackKeys: lib.tracks.map(\.seratoPath))] + lib.root.children.map(map)
        }
    }

    private func findNode(_ id: String, in list: [BrowserNode]) -> BrowserNode? {
        for n in list {
            if n.id == id { return n }
            if let c = n.children, let f = findNode(id, in: c) { return f }
        }
        return nil
    }

    // MARK: Tracks

    var rows: [BrowserTrack] {
        guard let id = selectedNodeID, let node = findNode(id, in: nodes) else { return [] }
        let fm = FileManager.default
        var out: [BrowserTrack] = []
        for (i, key) in node.trackKeys.enumerated() {
            switch source {
            case .rekordbox:
                guard let t = rekordbox?.tracks[key] else { continue }
                let sp = SeratoCrate.seratoPath(forFile: t.path, seratoFolder: seratoFolder)
                out.append(BrowserTrack(id: "\(i)-\(key)", key: key, title: t.title, artist: t.artist,
                                        bpm: t.bpm > 0 ? String(format: "%.2f", t.bpm) : "", musicalKey: t.key,
                                        path: t.path, exists: fm.fileExists(atPath: t.path),
                                        inOther: sp.flatMap { serato?.info(for: $0) } != nil))
            case .serato:
                let abs = SeratoLibraryReader.absolutePath(seratoPath: key, seratoFolder: seratoFolder)
                let info = serato?.info(for: key)
                out.append(BrowserTrack(id: "\(i)-\(key)", key: key,
                                        title: info?.title.isEmpty == false ? info!.title : (abs as NSString).lastPathComponent,
                                        artist: info?.artist ?? "", bpm: info?.bpm ?? "", musicalKey: info?.key ?? "",
                                        path: abs, exists: fm.fileExists(atPath: abs),
                                        inOther: rbByPath[Self.norm(abs)] != nil))
            }
        }
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return out }
        return out.filter { "\($0.title) \($0.artist) \($0.path)".lowercased().contains(f) }
    }

    // MARK: Detail

    static func time(_ s: Double) -> String {
        let ms = Int((s * 1000).rounded())
        return String(format: "%d:%02d.%03d", ms / 60000, (ms / 1000) % 60, ms % 1000)
    }

    func loadDetail() {
        detailTask?.cancel()
        guard let rowID = selectedTrackID, let row = rows.first(where: { $0.id == rowID }) else { detail = nil; return }
        var d = TrackDetail(title: row.artist.isEmpty ? row.title : "\(row.artist) – \(row.title)", path: row.path)

        let rbID = source == .rekordbox ? row.key : rbByPath[Self.norm(row.path)]
        if let id = rbID, let t = rekordbox?.tracks[id] {
            let slots = Array("ABCDEFGH")
            d.rekordboxCues = t.marks.sorted { $0.start < $1.start }.map { m in
                let kind = m.isLoop ? (m.isHot ? "Hot loop" : "Memory loop") : (m.isHot ? "Hot cue" : "Memory cue")
                let slot = m.isHot && m.num < 8 ? String(slots[m.num]) : "–"
                let time = m.isLoop ? "\(Self.time(m.start)) → \(Self.time(m.end!))" : Self.time(m.start)
                return CueRow(kind: kind, slot: slot, time: time, name: m.name, color: m.color)
            }
            if let first = t.tempos.min(by: { $0.position < $1.position }) {
                d.rekordboxGrid = String(format: "%.2f BPM, first beat %@, %d tempo marker(s)", first.bpm, Self.time(first.position), t.tempos.count)
            } else { d.rekordboxGrid = "No beatgrid" }
        }
        detail = d

        let path = row.path
        detailTask = Task { [weak self] in
            let result: (SeratoDecodedMarkers?, [SeratoBeatMarker]?, String?) = await Task.detached {
                guard FileManager.default.fileExists(atPath: path) else { return (nil, nil, "File not found") }
                guard AudioTagWriter.supports(path) else { return (nil, nil, "File type can't hold Serato cues") }
                do {
                    let r = try AudioTagWriter.readSerato(from: URL(fileURLWithPath: path))
                    return (r.markers2.map(SeratoTags.decodeMarkers), r.beatGrid.map(SeratoTags.decodeBeatGrid), nil)
                } catch { return (nil, nil, error.localizedDescription) }
            }.value
            guard let self, !Task.isCancelled, self.selectedTrackID == rowID else { return }
            var d = self.detail ?? TrackDetail()
            d.seratoNote = result.2
            if let m = result.0 {
                d.seratoCues = m.cues.map {
                    CueRow(kind: "Hot cue", slot: "\(Int($0.index) + 1)", time: Self.time(Double($0.positionMs) / 1000), name: $0.name,
                           color: SeratoCueColor.displayed(forStored: $0.color))   // what Serato shows on screen
                } + m.loops.map {
                    CueRow(kind: "Saved loop", slot: "\(Int($0.index) + 1)",
                           time: "\(Self.time(Double($0.startMs) / 1000)) → \(Self.time(Double($0.endMs) / 1000))", name: $0.name, color: nil)
                }
                if m.bpmLock { d.seratoNote = "Beatgrid locked" }
            } else if result.2 == nil {
                d.seratoNote = "No Serato cues in this file yet"
            }
            if let g = result.1, let first = g.first {
                let bpm = g.last?.bpm ?? 0
                d.seratoGrid = String(format: "%.2f BPM (last segment), first beat %@, %d marker(s)", bpm, Self.time(Double(first.position)), g.count)
            } else if result.2 == nil { d.seratoGrid = "No Serato beatgrid" }
            self.detail = d
        }
    }
}

// MARK: - Views

struct LibrarySidebar: View {
    @EnvironmentObject var vm: SyncViewModel
    @EnvironmentObject var bm: BrowserModel

    var body: some View {
        Group {
            if bm.source == .rekordbox && vm.library == nil {
                ContentUnavailableView {
                    Label("No rekordbox library", systemImage: "music.note.list")
                } description: {
                    Text("Choose your rekordbox XML export first.")
                } actions: {
                    Button("Choose XML…") { vm.chooseXML() }
                }
            } else if bm.source == .serato && bm.serato == nil {
                ContentUnavailableView("Can't read the Serato library", systemImage: "exclamationmark.triangle",
                                       description: Text(bm.seratoError ?? vm.seratoFolder.path))
            } else {
                List(bm.nodes, children: \.children, selection: $bm.selectedNodeID) { node in
                    Label(node.name, systemImage: node.icon).lineLimit(1).tag(node.id)
                }
                .listStyle(.sidebar)
            }
        }
        // The rekordbox | Serato switch sits above the library structure.
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Library", selection: $bm.source) {
                ForEach(BrowserSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct LibraryDetail: View {
    @EnvironmentObject var bm: BrowserModel

    var body: some View {
        let rows = bm.rows
        Table(rows, selection: $bm.selectedTrackID) {
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("BPM", value: \.bpm).width(min: 50, ideal: 60, max: 80)
            TableColumn("Key", value: \.musicalKey).width(min: 40, ideal: 45, max: 70)
            TableColumn("File") { r in
                Image(systemName: r.exists ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(r.exists ? Color.green : Color.orange)
                    .help(r.exists ? "File found" : "File missing")
            }
            .width(36)
            TableColumn(bm.source == .rekordbox ? "In Serato" : "In rekordbox") { r in
                Image(systemName: r.inOther ? "link" : "minus")
                    .foregroundStyle(r.inOther ? Color.accentColor : Color.secondary)
                    .help(r.inOther ? "The same audio file is in the other library" : "Not in the other library")
            }
            .width(78)
            TableColumn("Location", value: \.path)
        }
        .overlay {
            if rows.isEmpty {
                if bm.filter.isEmpty {
                    ContentUnavailableView("No tracks", systemImage: "music.note",
                                           description: Text("This playlist or crate is empty."))
                } else {
                    ContentUnavailableView.search(text: bm.filter)
                }
            }
        }
        .searchable(text: $bm.filter, placement: .toolbar, prompt: "Filter tracks")
        .navigationTitle(bm.selectedNodeName)
        .navigationSubtitle("\(rows.count) tracks · \(bm.source.rawValue)")
    }
}

struct TrackInspector: View {
    @EnvironmentObject var bm: BrowserModel

    var body: some View {
        Group {
            if let d = bm.detail {
                Form {
                    Section {
                        Text(d.title).font(.headline)
                        Text(d.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    cueSection("rekordbox · from XML", cues: d.rekordboxCues, grid: d.rekordboxGrid,
                               note: d.rekordboxCues == nil ? "Not in the loaded rekordbox XML" : nil)
                    cueSection("Serato · stored in the file", cues: d.seratoCues, grid: d.seratoGrid, note: d.seratoNote)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No track selected", systemImage: "waveform",
                                       description: Text("Select a track to compare its cues and beatgrid in rekordbox and Serato."))
            }
        }
        .navigationTitle("Track Details")
    }

    @ViewBuilder func cueSection(_ title: String, cues: [CueRow]?, grid: String?, note: String?) -> some View {
        Section(title) {
            if let grid { Label(grid, systemImage: "metronome").font(.callout) }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            ForEach(cues ?? []) { c in
                HStack(spacing: 8) {
                    Circle()
                        .fill(c.color.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) }
                              ?? Color.secondary.opacity(0.4))
                        .frame(width: 10, height: 10)
                    Text(c.slot).font(.callout.monospaced()).frame(width: 16, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.time).font(.callout.monospacedDigit())
                        Text(c.name.isEmpty ? c.kind : "\(c.kind) · \(c.name)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

import SwiftUI
import SyncCore

enum AppSection: String, CaseIterable, Identifiable {
    case sync = "Sync"
    case library = "Library"
    var id: Self { self }
}

/// Window layout: sidebar (navigation) · content · inspector, with actions in the toolbar.
/// On macOS 26+ the system renders sidebar, toolbar and inspector in Liquid Glass;
/// on macOS 14/15 the same containers use the classic appearance.
struct ContentView: View {
    @EnvironmentObject var vm: SyncViewModel
    @StateObject private var browser = BrowserModel()
    @AppStorage("section") private var section: AppSection = .sync
    @SceneStorage("showInspector") private var showInspector = false

    var body: some View {
        NavigationSplitView {
            Group {
                switch section {
                case .sync: SyncSidebar()
                case .library: LibrarySidebar()
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
        } detail: {
            Group {
                switch section {
                case .sync: SyncDetail()
                case .library: LibraryDetail()
                }
            }
            .inspector(isPresented: $showInspector) {
                Group {
                    switch section {
                    case .sync: ActivityLog()
                    case .library: TrackInspector()
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
        }
        .environmentObject(browser)
        .toolbar { toolbar }
        .onChange(of: vm.isRunning) { _, running in
            if running && section == .sync { showInspector = true }
        }
        .onChange(of: vm.libraryVersion, initial: true) { _, _ in
            browser.reload(rekordbox: vm.library, seratoFolder: vm.seratoFolder)
        }
        .onChange(of: browser.selectedTrackID) { _, id in
            if id != nil && section == .library { showInspector = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshXMLIfNeeded()
        }
        .alert("Rekordbox → Serato", isPresented: Binding(get: { vm.alert != nil }, set: { if !$0 { vm.alert = nil } })) {
            Button("OK") { vm.alert = nil }
        } message: { Text(vm.alert ?? "") }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Section", selection: $section) {
                ForEach(AppSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch section {
            case .sync:
                Button { vm.run(dryRun: true) } label: { Label("Preview", systemImage: "eye") }
                    .help("Dry run: list what would change without writing anything")
                    .disabled(vm.library == nil || vm.isRunning)
                Button { vm.run(dryRun: false) } label: {
                    Label("Sync to Serato", systemImage: "arrow.triangle.2.circlepath")
                }
                .labelStyle(.titleAndIcon)
                .adaptivePrimaryButton()
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Write crates, library entries, cues and beatgrids to Serato")
                .disabled(vm.library == nil || vm.isRunning || (vm.selected.isEmpty && !vm.tagWholeCollection))
            case .library:
                Button { browser.reload(rekordbox: vm.library, seratoFolder: vm.seratoFolder) } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Re-read the rekordbox XML data and the Serato folder")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showInspector.toggle() } label: {
                Label(section == .sync ? "Activity" : "Track Details", systemImage: "sidebar.trailing")
            }
            .help(section == .sync ? "Show the sync log" : "Compare cues and beatgrid of the selected track")
        }
    }
}

// MARK: - Sync

struct SyncSidebar: View {
    @EnvironmentObject var vm: SyncViewModel

    var body: some View {
        Group {
            if let lib = vm.library {
                List {
                    Section {
                        OutlineGroup(lib.root.children, children: \.childNodes) { NodeRow(node: $0) }
                    } header: {
                        HStack {
                            Text("Playlists → Crates")
                            Spacer()
                            Button("All") { vm.selectAll(true) }
                            Button("None") { vm.selectAll(false) }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView {
                    Label("No rekordbox library", systemImage: "music.note.list")
                } description: {
                    Text("Export your collection from rekordbox (File ▸ Export Collection in xml format). The app finds it automatically.")
                } actions: {
                    Button { vm.detectXML(userInitiated: true) } label: {
                        if vm.isDetecting { ProgressView().controlSize(.small) } else { Text("Find Automatically") }
                    }
                    .adaptivePrimaryButton()
                    .disabled(vm.isDetecting)
                    Button("Choose XML…") { vm.chooseXML() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if vm.library != nil {
                Text("\(vm.selected.count) playlists · \(vm.selectedTrackCount) tracks selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
    }
}

struct NodeRow: View {
    @EnvironmentObject var vm: SyncViewModel
    let node: RBNode

    var body: some View {
        Toggle(isOn: Binding(get: { vm.isSelected(node) }, set: { vm.setSelected(node, $0) })) {
            HStack {
                Label(node.name, systemImage: node.isFolder ? "folder" : "music.note.list").lineLimit(1)
                Spacer()
                if !node.isFolder {
                    Text("\(node.trackIDs.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

struct SyncDetail: View {
    @EnvironmentObject var vm: SyncViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Text(vm.xmlURL?.path ?? (vm.isDetecting ? "Looking…" : "Not found yet"))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(vm.xmlURL == nil ? .secondary : .primary)
                        Button { vm.detectXML(userInitiated: true) } label: {
                            if vm.isDetecting { ProgressView().controlSize(.small) } else { Image(systemName: "sparkle.magnifyingglass") }
                        }
                        .help("Find the rekordbox XML automatically")
                        .disabled(vm.isDetecting)
                        Button("Choose…") { vm.chooseXML() }
                        Button { vm.loadXML() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Reload XML").disabled(vm.xmlURL == nil)
                    }
                } label: {
                    Text("rekordbox XML")
                    if let source = vm.xmlSource {
                        Text("Found automatically · \(source)")
                    } else if vm.xmlURL != nil {
                        Text("Chosen manually")
                    }
                }
                LabeledContent("Serato folder") {
                    HStack {
                        Text(vm.seratoFolder.path).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { vm.chooseSeratoFolder() }
                    }
                }
            } header: {
                Text("Source & destination")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Only the exported XML is read; your rekordbox database is never opened or changed. A newer export is picked up automatically when you switch back to this app.")
                    if vm.rekordboxAutoExportEnabled == false {
                        Label("Tip: rekordbox can keep this XML up to date by itself. Turn on its automatic collection XML export in rekordbox's Preferences, and this app always syncs your latest library.", systemImage: "lightbulb")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Crates & library") {
                Toggle("Create crates from playlists (folders become parent crates)", isOn: $vm.writeCrates)
                TextField("Parent crate", text: $vm.rootCrateName, prompt: Text("leave empty for top level"))
                Toggle("Remove crates from earlier syncs that no longer exist in rekordbox", isOn: $vm.removeStaleCrates)
                Toggle("Add tracks to Serato's library (database V2)", isOn: $vm.addToDatabase)
                Toggle("Back up Serato database & crates before syncing", isOn: $vm.backup)
            }

            Section {
                Toggle("Copy shared DJ settings from rekordbox to Serato", isOn: $vm.syncSettings)
                ForEach(vm.settingsPlan) { c in
                    LabeledContent(c.title) {
                        HStack(spacing: 6) {
                            Text(c.new == 1 ? "On" : "Off")
                            if c.isChange {
                                Text(c.isSetInSerato ? "Serato: \(c.current == 1 ? "on" : "off")" : "Serato: default")
                                    .font(.caption).foregroundStyle(.orange)
                            } else {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Serato already matches")
                            }
                        }
                    }
                    .disabled(!vm.syncSettings)
                }
            } header: {
                Text("DJ settings")
            } footer: {
                Text("Settings both apps share are copied from rekordbox, so Serato behaves the same. rekordbox is only read. Serato's settings are backed up before every change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { vm.refreshSettingsPlan() }

            Section {
                Toggle("Hot cues", isOn: $vm.writeCues)
                Picker("Memory cues", selection: $vm.memoryCueMode) {
                    ForEach(MemoryCueMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!vm.writeCues)
                Toggle("Loops → Serato saved loops", isOn: $vm.includeLoops).disabled(!vm.writeCues)
                Toggle("Beatgrids", isOn: $vm.writeGrids)
                Toggle("Lock beatgrids in Serato", isOn: $vm.lockGrids).disabled(!vm.writeCues)
                Toggle("Apply to the whole collection (not only selected playlists)", isOn: $vm.tagWholeCollection)
                Toggle("Correct MP3 timing automatically (per file)", isOn: $vm.autoMP3Timing)
                LabeledContent("Extra MP3 offset") {
                    HStack {
                        TextField("MP3 offset", value: $vm.mp3OffsetMs, format: .number)
                            .labelsHidden().frame(width: 70)
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Cues & beatgrids")
            } footer: {
                Text("Every sync makes Serato match rekordbox: cues, loops and beatgrids you changed in Serato are replaced. Cue colours become the Serato colour that looks closest. MP3s are shifted per file to make up for how rekordbox and Serato decode them. Only Serato's own data is written; audio and other tags stay untouched, and rekordbox's own sampler files are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync to Serato")
        .navigationSubtitle(vm.library.map { "\($0.tracks.count) tracks in rekordbox" } ?? "")
        .safeAreaInset(edge: .bottom) { StatusBar() }
    }
}

/// Floating status surface over the content: the only custom glass in the app.
struct StatusBar: View {
    @EnvironmentObject var vm: SyncViewModel

    var body: some View {
        ZStack {
            if vm.statusVisible || vm.isRunning { bar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.smooth(duration: 0.35), value: vm.statusVisible || vm.isRunning)
    }

    var bar: some View {
        HStack(spacing: 12) {
            if vm.isRunning {
                ProgressView(value: vm.progress).frame(width: 140)
            } else {
                Image(systemName: vm.progress >= 1 ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(vm.progress >= 1 ? Color.green : Color.secondary)
            }
            Text(vm.status)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if vm.isRunning {
                // Plain button: no glass on top of glass.
                Button("Cancel", role: .cancel) { vm.cancel() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .adaptiveGlass(in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }
}

struct ActivityLog: View {
    @EnvironmentObject var vm: SyncViewModel

    var body: some View {
        Group {
            if vm.log.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "text.alignleft",
                                       description: Text("Run a preview or a sync to see what happens here."))
            } else {
                ScrollViewReader { proxy in
                    List(vm.log) { line in
                        Label {
                            Text(line.message).font(.callout).textSelection(.enabled)
                        } icon: {
                            Image(systemName: icon(line.level)).foregroundStyle(color(line.level))
                        }
                        .id(line.id)
                    }
                    .onChange(of: vm.log.count) { _, _ in
                        if let last = vm.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Activity")
    }

    func icon(_ l: SyncLogLine.Level) -> String {
        switch l {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    func color(_ l: SyncLogLine.Level) -> Color {
        switch l {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

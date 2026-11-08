// Self-test: `swift run SyncSelfTest <empty work dir>`
// Generates audio files with afconvert, writes Serato tags, verifies read-back
// and that decoded audio is bit-identical before/after.
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
@testable import SyncCore

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--preview" {
    exit(runPreview())
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--mp3case" {
    for f in CommandLine.arguments.dropFirst(2) {
        let c = MP3TimingCase.detect(url: URL(fileURLWithPath: f))
        print("\(c.map { "case \($0.rawValue) (\($0.explanation)), Serato offset +\(Int($0.seratoOffsetMs)) ms" } ?? "unreadable")  \((f as NSString).lastPathComponent)")
    }
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--inspect" {
    exit(runInspect(xml: CommandLine.arguments[2]))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--colors" {
    // How each rekordbox hot cue colour maps to Serato (displayed colour shown).
    let rekordbox: [(String, UInt32)] = [
        ("Pink", 0xDE44CF), ("Purple", 0xB432FF), ("Lilac", 0xAA42FF), ("Periwinkle", 0x6473FF), ("Blue", 0x305AFF),
        ("Sky", 0x50B4FF), ("Aqua", 0x00E0FF), ("Teal", 0x1FA382), ("Sea green", 0x10B176), ("Green", 0x28E214),
        ("Lime", 0xA5E116), ("Olive", 0xB4BE04), ("Mustard", 0xC3AF04), ("Orange", 0xE0641B), ("Red", 0xE62828), ("Hot pink", 0xFF127B),
    ]
    for (name, hex) in rekordbox {
        let s = SeratoCueColor.closest(to: RGB(hex: hex))
        print(String(format: "%-11@ #%06X  →  Serato %-10@ shows #%@ (stored #%@)", name as NSString, hex, "\(s)" as NSString, s.displayed.hex, s.stored.hex))
    }
    exit(0)
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--detect" {
    // Shows what the app's automatic rekordbox XML detection finds on this Mac (read-only).
    let start = Date()
    let found = RekordboxXMLLocator.candidates()
    let s = RekordboxSettings.read(home: FileManager.default.homeDirectoryForCurrentUser)
    print("rekordbox settings: \(s.map { "auto-export \($0.autoExportEnabled ? "ON" : "off") \($0.autoExportFile ?? ""), xml setting: \($0.importedLibraryFile ?? "-")" } ?? "not found")")
    if found.isEmpty { print("No rekordbox XML found.") }
    for c in found { print("• \(c.url.path)  [\(c.source.rawValue), modified \(c.modified)]") }
    print(String(format: "(took %.2f s)", Date().timeIntervalSince(start)))
    exit(0)
}
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--real" {
    exit(runRealFileTest(listFile: CommandLine.arguments[2], work: URL(fileURLWithPath: CommandLine.arguments[3])))
}

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ✓ \(msg)" : "  ✗ FAIL: \(msg)")
    if !cond { failures += 1 }
}

let work = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory() + "rb2s-selftest")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

@discardableResult
func sh(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus
}

// --- 1. Encoders -------------------------------------------------------------
print("Encoders")
let crate = SeratoCrate.build(trackPaths: ["Users/me/Music/a b.mp3", "Volumes/USB/ünïcode.flac"])
check(SeratoCrate.readTrackPaths(crate) == ["Users/me/Music/a b.mp3", "Volumes/USB/ünïcode.flac"], "crate round-trip")
check(SeratoCrate.fileName(for: ["Rekordbox", "House/Tech", "Deep"]) == "Rekordbox%%House-Tech%%Deep.crate", "crate file name")
check(SeratoCrate.seratoPath(forFile: "/Users/dj/x.mp3", seratoFolder: URL(fileURLWithPath: "/Users/dj/Music/_Serato_")) == "Users/dj/x.mp3", "path on startup disk")
check(SeratoCrate.seratoPath(forFile: "/Volumes/USB/Music/x.mp3", seratoFolder: URL(fileURLWithPath: "/Volumes/USB/_Serato_")) == "Music/x.mp3", "path on external drive")

var track = RBTrack(id: "1")
track.title = "Test"; track.path = "/x.mp3"
track.tempos = [RBTempo(position: 0.1, bpm: 128, beatInBar: 3)]
track.marks = [
    RBPositionMark(name: "Drop", type: 0, start: 30.0, end: nil, num: 2, color: RGB(40, 226, 20)),
    RBPositionMark(name: "", type: 0, start: 1.0, end: nil, num: 0, color: nil),
    RBPositionMark(name: "Mem", type: 0, start: 45.5, end: nil, num: -1, color: nil),
    RBPositionMark(name: "", type: 0, start: 30.0, end: nil, num: -1, color: nil),          // duplicate of hot cue
    RBPositionMark(name: "Loop", type: 4, start: 60, end: 61.875, num: 5, color: RGB(255, 0, 0)),
    RBPositionMark(name: "", type: 4, start: 90, end: 92, num: -1, color: nil),
]
let r = Converter.cuesAndLoops(for: track, options: ConversionOptions())
check(r.cues.map(\.index) == [0, 1, 2, 5], "cue slots: hot A, memory→B, hot C, loop pad F (got \(r.cues.map(\.index)))")
check(r.cues.first { $0.index == 2 }?.positionMs == 30000 && r.cues.first { $0.index == 2 }?.color == SeratoCueColor.brightGreen.stored, "hot cue position & colour mapping")
// rekordbox's 16 hot cue colours land on the Serato colour a DJ would expect
let expected: [(UInt32, SeratoCueColor)] = [
    (0xE62828, .red), (0xE0641B, .orange), (0xC3AF04, .yellow), (0x28E214, .brightGreen), (0x10B176, .green),
    (0x00E0FF, .cyan), (0x1FA382, .cyan), (0x50B4FF, .skyBlue), (0x305AFF, .blue), (0xB432FF, .purple),
    (0xAA42FF, .purple), (0xDE44CF, .pink), (0xFF127B, .crimson),
]
for (hex, want) in expected {
    let got = SeratoCueColor.closest(to: RGB(hex: hex))
    check(got == want, String(format: "rekordbox #%06X → Serato \(want)", hex) + (got == want ? "" : " (got \(got))"))
}
check(SeratoCueColor.displayed(forStored: RGB(hex: 0x00CC88)) == RGB(hex: 0x2B3673), "stored → displayed colour (jade is shown as navy)")
check(r.cues.first { $0.index == 1 }?.positionMs == 45500, "memory cue moved into free slot")
check(r.loops.count == 2 && r.loops.first { $0.index == 5 }?.endMs == 61875 && r.loops.first { $0.index == 0 }?.startMs == 90000, "loops (hot loop keeps slot, memory loop added)")

let grid = Converter.beatGrid(for: track)
check(grid.count == 1 && abs(grid[0].position - Float(0.1 + 2 * 60.0 / 128)) < 0.0001 && grid[0].bpm == 128, "grid starts on downbeat")
var vt = track
vt.tempos = [RBTempo(position: 0, bpm: 120, beatInBar: 1), RBTempo(position: 2, bpm: 120, beatInBar: 1),
             RBTempo(position: 8, bpm: 130, beatInBar: 1)]
let vg = Converter.beatGrid(for: vt)
check(vg.count == 2 && vg[0].beatsToNext == 16 && vg[1].bpm == 130, "variable grid collapses redundant markers")

let m2 = SeratoTags.markers2Raw(cues: r.cues, loops: r.loops, bpmLock: true)
let id3m2 = SeratoTags.markers2ForID3(m2)
check(id3m2.count >= 470 && SeratoTags.decodeMarkers2(id3Payload: id3m2) == m2, "markers2 base64 round-trip")
let entries = SeratoTags.parseMarkers2Entries(m2)
check(entries.map(\.name) == ["COLOR", "CUE", "CUE", "CUE", "CUE", "LOOP", "LOOP", "BPMLOCK"], "markers2 entries \(entries.map(\.name))")
let bg = SeratoTags.beatGridRaw(vg)
check(bg.count == 2 + 4 + 16 + 1 && bg.be32(2) == 2, "beatgrid layout")

// --- 2. Audio files ----------------------------------------------------------
print("Audio files")
// 3 s stereo 44.1k 16-bit sine as base WAV
func makeWAV(_ url: URL) {
    let frames = 44100 * 3
    var pcm: [UInt8] = []
    for i in 0 ..< frames {
        let s = Int16(sin(Double(i) * 2 * .pi * 440 / 44100) * 12000)
        for _ in 0 ..< 2 { pcm.append(UInt8(UInt16(bitPattern: s) & 0xFF)); pcm.append(UInt8(UInt16(bitPattern: s) >> 8)) }
    }
    var d = Bytes.latin1("RIFF"); d.appendLE32(UInt32(36 + pcm.count)); d += Bytes.latin1("WAVEfmt ")
    d.appendLE32(16); d += [1, 0, 2, 0]; d.appendLE32(44100); d.appendLE32(44100 * 4); d += [4, 0, 16, 0]
    d += Bytes.latin1("data"); d.appendLE32(UInt32(pcm.count)); d += pcm
    try! Data(d).write(to: url)
}
let base = work.appendingPathComponent("base.wav")
makeWAV(base)

var files: [URL] = []
let wav = work.appendingPathComponent("t.wav"); try FileManager.default.copyItem(at: base, to: wav); files.append(wav)
for (ext, fmt) in [("aiff", ["-f", "AIFF", "-d", "BEI16"]), ("flac", ["-f", "flac", "-d", "flac"]),
                   ("m4a", ["-f", "m4af", "-d", "aac"]), ("alac.m4a", ["-f", "m4af", "-d", "alac"])] {
    let u = work.appendingPathComponent("t.\(ext)")
    if sh(["afconvert"] + fmt + [base.path, u.path]) == 0 { files.append(u) } else { print("  (afconvert could not make .\(ext), skipped)") }
}
// Synthetic MP3: existing ID3v2.3 tag with a title frame + fake audio bytes.
let mp3 = work.appendingPathComponent("t.mp3")
var fakeAudio: [UInt8] = (0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
var t3 = ID3Tag(major: 3); t3.frames = [ID3Frame(id: "TIT2", flags: [0, 0], body: [0] + Bytes.latin1("My Title"))]
try Data(t3.serialize(totalSize: t3.frameBytes().count + 10) + fakeAudio).write(to: mp3)
files.append(mp3)

func decoded(_ u: URL) -> Data? {
    if u.pathExtension == "mp3" {
        let d = [UInt8](try! Data(contentsOf: u))
        return Data(d.suffix(fakeAudio.count))
    }
    let out = work.appendingPathComponent("dec-\(UUID().uuidString).caf")
    guard sh(["afconvert", "-f", "caff", "-d", "LEI16", u.path, out.path]) == 0 else { return nil }
    defer { try? FileManager.default.removeItem(at: out) }
    // compare only the audio data chunk payload region (skip CAF header which can contain metadata)
    let d = try! Data(contentsOf: out)
    return d.suffix(44100 * 3 * 4)
}

let bigGrid = SeratoTags.beatGridRaw(vg)
let p1 = SeratoTagPayload(markers2Raw: m2, beatGridRaw: bigGrid)
var manyCues = r.cues
for i in UInt8(0) ..< 8 { manyCues.append(SeratoCue(index: i, positionMs: UInt32(i) * 1000, color: RGB(hex: 0xCC0000), name: String(repeating: "x", count: 200))) }
let p2 = SeratoTagPayload(markers2Raw: SeratoTags.markers2Raw(cues: manyCues, loops: [], bpmLock: false), beatGridRaw: SeratoTags.beatGridRaw(grid))
let p3 = SeratoTagPayload(markers2Raw: SeratoTags.markers2Raw(cues: [], loops: [], bpmLock: false), beatGridRaw: nil)

for f in files {
    let name = f.lastPathComponent
    let before = decoded(f)
    do {
        for (i, p) in [p1, p2, p3].enumerated() {
            try AudioTagWriter.write(p, to: f)
            let back = try AudioTagWriter.readSerato(from: f)
            check(back.markers2 == p.markers2Raw, "\(name) pass \(i + 1): markers2 read back")
            let expectGrid = p.beatGridRaw ?? (i == 2 ? p2.beatGridRaw : nil)
            check(back.beatGrid == expectGrid, "\(name) pass \(i + 1): beatgrid read back")
        }
        if f.pathExtension != "mp3" { check(sh(["afinfo", f.path]) == 0, "\(name) still readable by CoreAudio") }
        let after = decoded(f)
        check(before != nil && before == after, "\(name) audio bit-identical after tagging")
        if f.pathExtension == "mp3" {
            let tag = try MP3Writer.read(f)
            check(tag?.frames.contains { $0.id == "TIT2" } == true, "mp3 keeps existing ID3 frames")
        }
    } catch {
        check(false, "\(name): \(error)")
    }
}

// --- 3. Full engine run --------------------------------------------------------
print("Engine")
let musicDir = work.appendingPathComponent("Music with spaces & ünï")
try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
let trackFile = musicDir.appendingPathComponent("song #1.aiff")
try FileManager.default.copyItem(at: work.appendingPathComponent("t.aiff"), to: trackFile)
let loc = URL(fileURLWithPath: trackFile.path).absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/").replacingOccurrences(of: "&", with: "&amp;")
let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<DJ_PLAYLISTS Version="1.0.0"><PRODUCT Name="rekordbox" Version="7.0.0" Company="AlphaTheta"/>
<COLLECTION Entries="2">
<TRACK TrackID="11" Name="Song &amp; One" Artist="Art" Kind="AIFF File" AverageBpm="128.00" Tonality="8A" Location="\(loc)">
<TEMPO Inizio="0.05" Bpm="128.00" Metro="4/4" Battito="1"/>
<POSITION_MARK Name="Intro" Type="0" Start="0.05" Num="0" Red="40" Green="226" Blue="20"/>
<POSITION_MARK Name="" Type="0" Start="1.5" Num="-1"/>
</TRACK>
<TRACK TrackID="12" Name="Missing" Artist="X" Kind="MP3 File" Location="file://localhost/nonexistent/x.mp3"/>
</COLLECTION>
<PLAYLISTS><NODE Type="0" Name="ROOT" Count="2">
<NODE Name="House" Type="0" Count="1"><NODE Name="Deep / Warm" Type="1" KeyType="0" Entries="2"><TRACK Key="11"/><TRACK Key="12"/></NODE></NODE>
<NODE Name="ByLocation" Type="1" KeyType="1" Entries="1"><TRACK Key="\(loc)"/></NODE>
</NODE></PLAYLISTS></DJ_PLAYLISTS>
"""
let xmlURL = work.appendingPathComponent("rekordbox.xml")
try xml.write(to: xmlURL, atomically: true, encoding: .utf8)
let lib = try RekordboxXMLParser.parse(url: xmlURL)
check(lib.tracks["11"]?.path == trackFile.path, "XML location decoded to real path")
check(lib.tracks["11"]?.title == "Song & One", "XML entities decoded")
let pls = lib.root.allPlaylists
check(pls.count == 2 && pls[0].trackIDs == ["11", "12"] && pls[1].trackIDs == ["11"], "playlists incl. KeyType=1")

let seratoDir = work.appendingPathComponent("_Serato_")
var opts = SyncOptions(seratoFolder: seratoDir, selectedPlaylistIDs: Set(pls.map(\.id)))
var logs: [String] = []
let rep = try SyncEngine(library: lib, options: opts, progress: { _, _ in }, log: { logs.append($0.message) }).run()
let crates = (try? FileManager.default.contentsOfDirectory(atPath: seratoDir.appendingPathComponent("Subcrates").path).sorted()) ?? []
check(crates == ["Rekordbox%%ByLocation.crate", "Rekordbox%%House%%Deep - Warm.crate", "Rekordbox%%House.crate", "Rekordbox.crate"], "crates \(crates)")
let deep = [UInt8](try Data(contentsOf: seratoDir.appendingPathComponent("Subcrates/Rekordbox%%House%%Deep - Warm.crate")))
check(SeratoCrate.readTrackPaths(deep) == [String(trackFile.path.dropFirst()), "nonexistent/x.mp3"], "crate track paths")
check(rep.tracksAddedToDatabase == 2 && rep.filesTagged == 1 && rep.filesMissing == 1, "report: \(rep.summary)")
let tagged = try AudioTagWriter.readSerato(from: trackFile)
let cueNames = SeratoTags.parseMarkers2Entries(tagged.markers2 ?? []).map(\.name)
check(cueNames.filter { $0 == "CUE" }.count == 2, "engine wrote hot + memory cue")
let rep2 = try SyncEngine(library: lib, options: opts, progress: { _, _ in }, log: { _ in }).run()
check(rep2.tracksAddedToDatabase == 0 && rep2.filesUnchanged == 1 && rep2.filesTagged == 0, "second sync is incremental")
opts.selectedPlaylistIDs = [pls[1].id]
let rep3 = try SyncEngine(library: lib, options: opts, progress: { _, _ in }, log: { _ in }).run()
check(rep3.cratesRemoved == 2, "deselected playlist's crates removed (\(rep3.cratesRemoved))")
check(rep2.backupFolder != nil, "backup created")


// --- 4. Same-file matching & Serato reader ------------------------------------
print("Same file / viewer")
let nfdName = "Beyonce\u{301} Remix.aiff"          // decomposed é, as Finder often stores it
let nfdFile = musicDir.appendingPathComponent(nfdName)
try FileManager.default.copyItem(at: work.appendingPathComponent("t.aiff"), to: nfdFile)
let onDisk = try FileManager.default.contentsOfDirectory(atPath: musicDir.path).first { $0.hasPrefix("Beyonc") }!
let nfcPath = musicDir.path + "/" + "Beyonc\u{e9} Remix.aiff"   // precomposed, as an XML might have it
let resolver = OnDiskPathResolver()
check(resolver.resolve(nfcPath) == musicDir.path + "/" + onDisk, "NFC path resolved to exact on-disk spelling")
check(resolver.resolve("/nonexistent/x.mp3") == "/nonexistent/x.mp3", "missing paths left unchanged")

var lib2 = lib
lib2.tracks["11"]?.path = nfcPath
var o2 = SyncOptions(seratoFolder: work.appendingPathComponent("_Serato2_"), selectedPlaylistIDs: Set(pls.map(\.id)))
o2.backup = false
_ = try SyncEngine(library: lib2, options: o2, progress: { _, _ in }, log: { _ in }).run()
let sl = try SeratoLibraryReader.read(seratoFolder: o2.seratoFolder)
let expectSerato = String((musicDir.path + "/" + onDisk).dropFirst())
check(sl.tracks.contains { $0.seratoPath == expectSerato }, "Serato database uses the on-disk spelling")
check(sl.root.children.map(\.name) == ["Rekordbox"] && sl.root.children[0].children.map(\.name) == ["ByLocation", "House"], "Serato crate tree read back")
check(sl.root.children[0].children[1].children.first?.trackPaths.count == 2, "crate tracks read back")
check(SeratoLibraryReader.absolutePath(seratoPath: expectSerato, seratoFolder: o2.seratoFolder) == musicDir.path + "/" + onDisk, "absolute path from Serato path")
let dec = try AudioTagWriter.readSerato(from: nfdFile)
let dm = SeratoTags.decodeMarkers(dec.markers2 ?? [])
check(dm.cues.count == 2 && dm.cues[0].positionMs == 50 && dm.cues[0].name == "Intro", "decoded Serato cues from file")
let dg = SeratoTags.decodeBeatGrid(dec.beatGrid ?? [])
check(dg.count == 1 && dg[0].bpm == 128, "decoded Serato beatgrid from file")


// --- 5. rekordbox XML auto-detection ------------------------------------------
print("XML auto-detection")
let home = work.appendingPathComponent("fakehome")
let fm2 = FileManager.default
for d in ["Documents", "Desktop", "Music/rekordbox", "Library/Application Support/Pioneer/rekordbox6", "Exports"] {
    try fm2.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true)
}
let rbXML = try String(contentsOf: xmlURL, encoding: .utf8)
func put(_ rel: String, _ text: String, age: TimeInterval) throws {
    let u = home.appendingPathComponent(rel)
    try text.write(to: u, atomically: true, encoding: .utf8)
    try fm2.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
}
try put("Documents/rekordbox.xml", rbXML, age: 3600)                    // older export
try put("Desktop/rekordbox.xml", rbXML, age: 60)                        // newest export
try put("Music/rekordbox/rekordbox.xml", "<?xml version=\"1.0\"?><PROPERTIES/>", age: 0) // not a collection
try put("Exports/auto.xml", rbXML, age: 7200)                           // rekordbox auto-export (oldest!)
func settings(autoExport: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <PROPERTIES>
      <VALUE name="bridgeImportedLibraryFile" val="\(home.path)/Library/rekordbox/rekordbox/rekordbox.xml"/>
      <VALUE name="CollectionAutoExportEnable" val="\(autoExport.isEmpty ? "0" : "1")"/>
      <VALUE name="CollectionAutoExportXmlFile" val="\(autoExport)"/>
    </PROPERTIES>
    """
}
let settingsFile = "Library/Application Support/Pioneer/rekordbox6/rekordbox3.settings"
try put(settingsFile, settings(autoExport: ""), age: 0)
check(RekordboxXMLLocator.isRekordboxXML(home.appendingPathComponent("Desktop/rekordbox.xml")), "recognises a rekordbox collection XML")
check(!RekordboxXMLLocator.isRekordboxXML(home.appendingPathComponent("Music/rekordbox/rekordbox.xml")), "rejects other XML files")
let st = RekordboxSettings.read(home: home)
check(st?.autoExportEnabled == false && st?.importedLibraryFile?.hasSuffix("rekordbox/rekordbox.xml") == true, "reads rekordbox settings")
let b1 = RekordboxXMLLocator.best(home: home, useSpotlight: false)
check(b1?.url.path == home.appendingPathComponent("Desktop/rekordbox.xml").path && b1?.source == .usualLocation, "picks the newest export (\(b1?.url.path ?? "nil"))")
try put(settingsFile, settings(autoExport: home.appendingPathComponent("Exports/auto.xml").path), age: 0)
let b2 = RekordboxXMLLocator.best(home: home, useSpotlight: false)
check(b2?.source == .autoExport && b2?.url.lastPathComponent == "auto.xml", "rekordbox auto-export wins even if older")
check(RekordboxSettings.read(home: home)?.autoExportEnabled == true, "detects auto-export enabled")
check(RekordboxXMLLocator.candidates(home: home, useSpotlight: false).count == 3, "lists all valid exports once")
let emptyHome = work.appendingPathComponent("emptyhome")
try fm2.createDirectory(at: emptyHome, withIntermediateDirectories: true)
check(RekordboxXMLLocator.best(home: emptyHome, useSpotlight: false) == nil, "nothing found in an empty home")


// --- 6. Sync always overrides Serato; MP3 timing; rekordbox-owned files -------
print("Override & timing")
// Simulate editing cues in Serato: write different markers into the synced file.
let edited = SeratoTagPayload(markers2Raw: SeratoTags.markers2Raw(cues: [SeratoCue(index: 0, positionMs: 99_000, color: SeratoCueColor.blue.stored, name: "edited in Serato")], loops: [], bpmLock: false), beatGridRaw: nil)
try AudioTagWriter.write(edited, to: trackFile)
opts.selectedPlaylistIDs = Set(pls.map(\.id))
let rep4 = try SyncEngine(library: lib, options: opts, progress: { _, _ in }, log: { _ in }).run()
let restored = SeratoTags.decodeMarkers(try AudioTagWriter.readSerato(from: trackFile).markers2 ?? [])
check(rep4.filesTagged == 1 && restored.cues.first?.name == "Intro" && restored.cues.count == 2, "re-sync replaces cues edited in Serato with rekordbox's")
let rep5 = try SyncEngine(library: lib, options: opts, progress: { _, _ in }, log: { _ in }).run()
check(rep5.filesTagged == 0 && rep5.filesUnchanged == 1, "files already matching rekordbox are left alone")
// BPM changed in rekordbox → Serato library entry updated, other fields kept
var lib3 = lib
lib3.tracks["11"]?.bpm = 124.5
let rep6 = try SyncEngine(library: lib3, options: opts, progress: { _, _ in }, log: { _ in }).run()
let db = try SeratoLibraryReader.read(seratoFolder: seratoDir)
check(rep6.tracksUpdatedInDatabase == 1 && rep6.tracksAddedToDatabase == 0, "existing Serato library entry updated, none duplicated")
check(db.tracks.first { $0.seratoPath.hasSuffix("song #1.aiff") }?.bpm == "124.50", "Serato library BPM follows rekordbox")
check(db.tracks.count == 2, "no duplicate entries in Serato's library")

// MP3 timing cases on synthetic first frames (MPEG1 layer III stereo, Xing at +36)
func frame(_ tag: String?, lame: String?, validCRC: Bool = true) -> [UInt8] {
    var f = [UInt8](repeating: 0, count: 417)
    f[0] = 0xFF; f[1] = 0xFB; f[2] = 0x90; f[3] = 0x00
    if let tag {
        f.replaceSubrange(36 ..< 40, with: Array(tag.utf8))
        f.replaceSubrange(40 ..< 44, with: [0, 0, 0, 0x0F])           // frames, bytes, TOC, quality
        if let lame {
            f.replaceSubrange(156 ..< 156 + lame.utf8.count, with: Array(lame.utf8))
            var crc = MP3TimingCase.crc16(f[0 ..< 190])
            if !validCRC { crc ^= 0xFFFF }
            f[190] = UInt8(crc >> 8); f[191] = UInt8(crc & 0xFF)
        }
    }
    return f
}
check(MP3TimingCase.classify(frame(nil, lame: nil)) == .a, "MP3 without Xing/Info → case A (0 ms)")
check(MP3TimingCase.classify(frame("Info", lame: nil)) == .b, "Xing/Info without LAME tag → case B (+27 ms)")
check(MP3TimingCase.classify(frame("Xing", lame: "Lavc59.37")) == .b, "FFmpeg (Lavc) encoded → case B")
check(MP3TimingCase.classify(frame("Info", lame: "LAME3.100", validCRC: false)) == .c, "LAME tag with bad CRC → case C (+34 ms)")
check(MP3TimingCase.classify(frame("Info", lame: "LAME3.100")) == .d, "valid LAME tag → case D (+10 ms)")
check(SyncEngine.isRekordboxOwned("/Users/x/Music/rekordbox/Sampler/GROOVE CIRCUIT/PRESET/a.wav")
      && !SyncEngine.isRekordboxOwned("/Users/x/Music/Tracks/a.wav"), "rekordbox's own sampler files are never tagged")

print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)

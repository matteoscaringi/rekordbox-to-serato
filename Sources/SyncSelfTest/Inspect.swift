// `swift run SyncSelfTest --inspect <rekordbox.xml>` (read-only)
// For every track whose file carries Serato data: how far each hot cue sits from the nearest
// beat in rekordbox's grid vs. the nearest beat of the Serato grid stored in the file.
import Foundation
@testable import SyncCore

func rekordboxBeats(_ t: RBTrack, until end: Double) -> [Double] {
    let tempos = t.tempos.filter { $0.bpm > 0 }.sorted { $0.position < $1.position }
    var beats: [Double] = []
    for (i, tp) in tempos.enumerated() {
        let stop = i + 1 < tempos.count ? tempos[i + 1].position - 0.0005 : end
        var x = tp.position
        while x < stop { beats.append(x); x += 60 / tp.bpm }
    }
    if let f = tempos.first {   // extend before the first marker
        var x = f.position - 60 / f.bpm
        while x > -1 { beats.insert(x, at: 0); x -= 60 / f.bpm }
    }
    return beats
}

func seratoBeats(_ g: [SeratoBeatMarker], until end: Double) -> [Double] {
    var beats: [Double] = []
    for (i, m) in g.enumerated() {
        let p = Double(m.position)
        if let n = m.beatsToNext, i + 1 < g.count {
            let step = (Double(g[i + 1].position) - p) / Double(n)
            for k in 0 ..< Int(n) { beats.append(p + Double(k) * step) }
        } else if let bpm = m.bpm {
            var x = p
            while x < end { beats.append(x); x += 60 / Double(bpm) }
        }
    }
    if let f = g.first, let first = beats.first {
        let step = beats.count > 1 ? beats[1] - beats[0] : 60 / Double(f.bpm ?? 120)
        var x = first - step
        while x > -1 { beats.insert(x, at: 0); x -= step }
    }
    return beats
}

func nearestOffset(_ t: Double, _ beats: [Double]) -> Double {
    beats.min { abs($0 - t) < abs($1 - t) }.map { t - $0 } ?? .nan
}

func runInspect(xml: String) -> Int32 {
    guard let lib = try? RekordboxXMLParser.parse(url: URL(fileURLWithPath: (xml as NSString).expandingTildeInPath)) else {
        print("cannot read XML"); return 1
    }
    var rows: [(String, String, Int, Int, Double, Double)] = []
    var inspected = 0
    for id in lib.trackOrder {
        guard let t = lib.tracks[id], FileManager.default.fileExists(atPath: t.path),
              AudioTagWriter.supports(t.path),
              let r = try? AudioTagWriter.readSerato(from: URL(fileURLWithPath: t.path)) else {
            if let t = lib.tracks[id], t.fileExtension == "wav", FileManager.default.fileExists(atPath: t.path) {
                do { _ = try AudioTagWriter.readSerato(from: URL(fileURLWithPath: t.path)) } catch { print("  WAV read error: \(t.title): \(error)") }
            }
            continue
        }
        guard let m2 = r.markers2, let gr = r.beatGrid else {
            if t.fileExtension == "wav" { print("  WAV without Serato data: \(t.title) (markers: \(r.markers2 != nil), grid: \(r.beatGrid != nil))") }
            continue
        }
        inspected += 1
        let grid = SeratoTags.decodeBeatGrid(gr)
        let cues = SeratoTags.decodeMarkers(m2).cues
        let end = Double(max(t.totalTime, 60)) + 5
        let rbB = rekordboxBeats(t, until: end), seB = seratoBeats(grid, until: end)
        for m in t.marks where m.isHot && !m.isLoop {
            guard let sc = cues.first(where: { Int($0.index) == m.num }) else { continue }
            let sPos = Double(sc.positionMs) / 1000
            let rbOff = nearestOffset(m.start, rbB) * 1000
            let seOff = nearestOffset(sPos, seB) * 1000
            rows.append((t.fileExtension, "\(t.artist) – \(t.title)", t.tempos.count, grid.count, rbOff, seOff))
        }
    }
    let offBeat = rows.map { abs($0.4) }
    for lim in [2.0, 5.0, 10.0, 20.0] {
        print(String(format: "  hot cues more than %2.0f ms from a beat in rekordbox itself: %d", lim, offBeat.filter { $0 > lim }.count))
    }
    for r in rows.filter({ abs($0.4) > 5 }).prefix(12) {
        print(String(format: "    %@ [%@]: cue is %+.1f ms from the beat in rekordbox", r.1, r.0, r.4))
    }
    let bad = rows.filter { abs($0.4 - $0.5) > 3 }
    print("Tracks inspected: \(inspected), hot cues: \(rows.count), cues whose beat offset differs by >3 ms: \(bad.count)")
    let byExt = Dictionary(grouping: rows, by: { $0.0 })
    for (ext, r) in byExt.sorted(by: { $0.key < $1.key }) {
        let diffs = r.map { $0.5 - $0.4 }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        print(String(format: "  .%@: %d cues, mean (Serato − rekordbox) offset to beat: %+.1f ms, max |diff| %.1f ms",
                     ext, r.count, mean, diffs.map(abs).max() ?? 0))
    }
    for b in bad.prefix(25) {
        print(String(format: "  %@  [%@, rb tempos %d → serato markers %d]  rekordbox cue→beat %+.1f ms, Serato cue→beat %+.1f ms",
                     b.1, b.0, b.2, b.3, b.4, b.5))
    }
    return 0
}

import Foundation

public struct SeratoCue: Equatable {
    public var index: UInt8
    public var positionMs: UInt32
    public var color: RGB
    public var name: String
}

public struct SeratoLoop: Equatable {
    public var index: UInt8
    public var startMs: UInt32
    public var endMs: UInt32
    public var name: String
    public var locked: Bool
}

public struct SeratoBeatMarker: Equatable {
    public var position: Float          // seconds
    public var beatsToNext: UInt32?     // non-terminal markers
    public var bpm: Float?              // terminal marker
}

public enum MemoryCueMode: String, CaseIterable, Identifiable, Codable {
    case fillEmptySlots = "Put memory cues in free hot cue slots"
    case ignore = "Ignore memory cues"
    public var id: String { rawValue }
}

public struct ConversionOptions {
    public var memoryCues: MemoryCueMode = .fillEmptySlots
    public var includeLoops = true
    /// Serato colour for cues that have none in rekordbox (memory cues).
    public var memoryCueColor = SeratoCueColor.red
    /// Added to every position (seconds). Used for the optional MP3 offset fix.
    public var timeOffset: Double = 0
    public init() {}
}

public enum Converter {
    /// Serato's default colour per hot cue slot 1–8 (as Serato assigns them).
    public static let defaultSlotColors: [SeratoCueColor] = [.red, .orange, .blue, .yellow, .brightGreen, .pink, .cyan, .purple]

    public static let maxSlots = 8

    public struct CueResult {
        public var cues: [SeratoCue]
        public var loops: [SeratoLoop]
        public var warnings: [String]
    }

    public static func cuesAndLoops(for track: RBTrack, options o: ConversionOptions) -> CueResult {
        func ms(_ s: Double) -> UInt32 { UInt32(max(0, min(Double(UInt32.max), ((s + o.timeOffset) * 1000).rounded()))) }
        /// Serato can only show its own 18 cue colours: pick the one that looks closest.
        func color(_ c: RGB?, fallback: SeratoCueColor) -> RGB {
            (c.map(SeratoCueColor.closest(to:)) ?? fallback).stored
        }

        var cues: [Int: SeratoCue] = [:]
        var loops: [Int: SeratoLoop] = [:]
        var warnings: [String] = []
        let marks = track.marks.sorted { $0.start < $1.start }

        func freeSlot<T>(_ d: [Int: T], preferred: Int? = nil) -> Int? {
            if let p = preferred, p >= 0, p < maxSlots, d[p] == nil { return p }
            return (0 ..< maxSlots).first { d[$0] == nil }
        }

        // 1. Hot cues keep their slot (A = 1 ... H = 8).
        for m in marks where m.isHot && !m.isLoop {
            guard let slot = freeSlot(cues, preferred: m.num), slot == m.num || m.num >= maxSlots else {
                warnings.append("duplicate hot cue \(m.num + 1) skipped"); continue
            }
            cues[slot] = SeratoCue(index: UInt8(slot), positionMs: ms(m.start),
                                   color: color(m.color, fallback: defaultSlotColors[slot % 8]), name: m.name)
        }

        // 2. Hot loops become Serato saved loops; also keep a cue on that pad.
        if o.includeLoops {
            for m in marks where m.isHot && m.isLoop {
                guard let slot = freeSlot(loops, preferred: m.num) else { warnings.append("no free loop slot"); continue }
                loops[slot] = SeratoLoop(index: UInt8(slot), startMs: ms(m.start), endMs: ms(m.end!),
                                         name: m.name, locked: false)
                if m.num < maxSlots, cues[m.num] == nil {
                    cues[m.num] = SeratoCue(index: UInt8(m.num), positionMs: ms(m.start),
                                            color: color(m.color, fallback: defaultSlotColors[m.num]), name: m.name)
                }
            }
        }

        // 3. Memory cues / memory loops (Serato has no memory cues).
        for m in marks where !m.isHot {
            if m.isLoop {
                guard o.includeLoops else { continue }
                let s = ms(m.start), e = ms(m.end!)
                if loops.values.contains(where: { $0.startMs == s && $0.endMs == e }) { continue }
                guard let slot = freeSlot(loops) else { warnings.append("memory loop dropped (8 loop slots full)"); continue }
                loops[slot] = SeratoLoop(index: UInt8(slot), startMs: s, endMs: e, name: m.name, locked: false)
            } else if o.memoryCues == .fillEmptySlots {
                let p = ms(m.start)
                if cues.values.contains(where: { abs(Int64($0.positionMs) - Int64(p)) <= 5 }) { continue }
                guard let slot = freeSlot(cues) else { warnings.append("memory cue dropped (8 hot cue slots full)"); continue }
                cues[slot] = SeratoCue(index: UInt8(slot), positionMs: p,
                                       color: color(m.color, fallback: o.memoryCueColor), name: m.name)
            }
        }

        return CueResult(cues: cues.values.sorted { $0.index < $1.index },
                         loops: loops.values.sorted { $0.index < $1.index }, warnings: warnings)
    }

    /// Converts the Rekordbox tempo list into Serato beatgrid markers.
    /// The first marker is moved onto a downbeat so Serato's bar lines line up.
    public static func beatGrid(for track: RBTrack, timeOffset: Double = 0) -> [SeratoBeatMarker] {
        let sorted = track.tempos.filter { $0.bpm > 0 && $0.position.isFinite }.sorted { $0.position < $1.position }
        guard var kept = sorted.first.map({ [$0] }) else { return [] }

        // Drop markers that don't change anything (same BPM, still on the grid).
        for t in sorted.dropFirst() {
            let last = kept[kept.count - 1]
            if abs(t.bpm - last.bpm) < 0.0005 {
                let beats = (t.position - last.position) * last.bpm / 60
                if abs(beats - beats.rounded()) < 0.02 { continue }
            }
            kept.append(t)
        }

        // Battito 1 = downbeat. Move forward to the next downbeat if needed.
        let beatIndex = ((kept[0].beatInBar - 1) % 4 + 4) % 4
        let shift = (4 - beatIndex) % 4
        if shift > 0 {
            let newPos = kept[0].position + Double(shift) * 60 / kept[0].bpm
            if kept.count == 1 || newPos < kept[1].position - 0.001 {
                kept[0].position = newPos
            }
        }

        var markers: [SeratoBeatMarker] = []
        for i in 0 ..< kept.count {
            let pos = Float(kept[i].position + timeOffset)
            if i == kept.count - 1 {
                markers.append(SeratoBeatMarker(position: pos, beatsToNext: nil, bpm: Float(kept[i].bpm)))
            } else {
                let beats = ((kept[i + 1].position - kept[i].position) * kept[i].bpm / 60).rounded()
                markers.append(SeratoBeatMarker(position: pos, beatsToNext: UInt32(max(1, beats)), bpm: nil))
            }
        }
        return markers
    }
}

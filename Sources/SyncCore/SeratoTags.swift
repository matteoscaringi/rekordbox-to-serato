import Foundation

/// Encoders for the binary blobs Serato stores inside audio files.
/// Formats documented by the community (github.com/Holzhaus/serato-tags, Mixxx).
public enum SeratoTags {
    // MARK: Markers2 (cues, loops, track colour, BPM lock)

    public static func markers2Raw(cues: [SeratoCue], loops: [SeratoLoop], bpmLock: Bool,
                                   trackColor: RGB = RGB(hex: 0xFFFFFF)) -> [UInt8] {
        var out: [UInt8] = [0x01, 0x01]
        func entry(_ name: String, _ data: [UInt8]) {
            out.append(contentsOf: Bytes.latin1(name)); out.append(0)
            out.appendBE32(UInt32(data.count)); out.append(contentsOf: data)
        }
        entry("COLOR", [0, trackColor.r, trackColor.g, trackColor.b])
        for c in cues {
            var d: [UInt8] = [0, c.index]
            d.appendBE32(c.positionMs)
            d.append(contentsOf: [0, c.color.r, c.color.g, c.color.b, 0, 0])
            d.append(contentsOf: Array(c.name.utf8)); d.append(0)
            entry("CUE", d)
        }
        for l in loops {
            var d: [UInt8] = [0, l.index]
            d.appendBE32(l.startMs); d.appendBE32(l.endMs)
            d.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x27, 0xAA, 0xE1, 0x00, l.locked ? 1 : 0])
            d.append(contentsOf: Array(l.name.utf8)); d.append(0)
            entry("LOOP", d)
        }
        entry("BPMLOCK", [bpmLock ? 1 : 0])
        out.append(0)
        return out
    }

    /// `01 01` + base64 (no '=' padding, newline every 72 chars).
    static func markers2Encoded(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x01, 0x01]
        var offset = 0
        while offset < raw.count {
            if offset > 0 { out.append(0x0A) }
            let block = Data(raw[offset ..< min(offset + 54, raw.count)])
            var b64 = block.base64EncodedString()
            while b64.hasSuffix("=") { b64.removeLast() }
            out.append(contentsOf: Array(b64.utf8))
            offset += 54
        }
        return out
    }

    /// GEOB payload for ID3 ("Serato Markers2"): padded to >= 470 bytes like Serato does.
    public static func markers2ForID3(_ raw: [UInt8]) -> [UInt8] {
        var d = markers2Encoded(raw)
        if d.count < 470 { d.append(contentsOf: [UInt8](repeating: 0, count: 470 - d.count)) } else { d.append(0) }
        return d
    }

    // MARK: BeatGrid

    public static func beatGridRaw(_ markers: [SeratoBeatMarker]) -> [UInt8] {
        var out: [UInt8] = [0x01, 0x00]
        out.appendBE32(UInt32(markers.count))
        for m in markers {
            out.appendFloatBE(m.position)
            if let beats = m.beatsToNext { out.appendBE32(beats) } else { out.appendFloatBE(m.bpm ?? 120) }
        }
        out.append(0x00)
        return out
    }

    // MARK: FLAC / MP4 envelope

    /// FLAC Vorbis comments and MP4 freeform atoms store base64 of
    /// "application/octet-stream\0\0<description>\0" + the ID3 GEOB payload.
    public static func base64Envelope(description: String, payload: [UInt8]) -> String {
        var d = Bytes.latin1("application/octet-stream"); d.append(0); d.append(0)
        d.append(contentsOf: Bytes.latin1(description)); d.append(0)
        d.append(contentsOf: payload)
        return Data(d).base64EncodedString()
    }

    // MARK: Decoders (used for verification)

    public static func decodeMarkers2(id3Payload: [UInt8]) -> [UInt8]? {
        guard id3Payload.count > 2, id3Payload[0] == 1, id3Payload[1] == 1 else { return nil }
        var text = String(decoding: id3Payload.dropFirst(2).prefix { $0 != 0 }, as: UTF8.self)
        text.removeAll { $0 == "\n" }
        switch text.count % 4 {
        case 2: text += "=="
        case 3: text += "="
        case 1: text += "A=="   // Serato quirk: a dangling 6-bit group
        default: break
        }
        return Data(base64Encoded: text).map { [UInt8]($0) }
    }

    public static func parseMarkers2Entries(_ raw: [UInt8]) -> [(name: String, data: [UInt8])] {
        var out: [(String, [UInt8])] = []
        var p = 2
        while p < raw.count, raw[p] != 0 {
            guard let nul = raw[p...].firstIndex(of: 0), nul + 5 <= raw.count else { break }
            let name = String(decoding: raw[p ..< nul], as: UTF8.self)
            let len = Int(raw.be32(nul + 1))
            let start = nul + 5
            guard start + len <= raw.count else { break }
            out.append((name, Array(raw[start ..< start + len])))
            p = start + len
        }
        return out
    }
}

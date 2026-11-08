import Foundation

/// rekordbox and Serato decode some MP3s with a different start offset, depending on how the
/// file was encoded. The classification follows mp3guessenc (as used by Mixxx); the offsets are
/// derived from Mixxx's measured rekordbox→CoreAudio and CoreAudio→Serato offsets:
///
///   case | file                                              | rekordbox→CA | CA→Serato | Serato − rekordbox
///   A    | no Xing/Info/VBRI header                          |   −12 ms     |  +12 ms   |   0 ms
///   B    | Xing/Info header without LAME tag, or "Lavc"      |   −13 ms     |  +40 ms   | +27 ms
///   C    | LAME tag present but its CRC doesn't verify       |   −26 ms     |  +60 ms   | +34 ms
///   D    | valid LAME tag, or a VBRI header                  |   −50 ms     |  +60 ms   | +10 ms
public enum MP3TimingCase: String {
    case a = "A", b = "B", c = "C", d = "D"

    /// Milliseconds to add to rekordbox positions to land on the same audio in Serato.
    public var seratoOffsetMs: Double {
        switch self {
        case .a: return 0
        case .b: return 27
        case .c: return 34
        case .d: return 10
        }
    }

    public var explanation: String {
        switch self {
        case .a: return "no Xing/Info header"
        case .b: return "Xing/Info header without LAME tag"
        case .c: return "LAME tag with invalid checksum"
        case .d: return "LAME/VBRI header"
        }
    }

    /// Reads only the first frame(s) of the file.
    public static func detect(url: URL) -> MP3TimingCase? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 10), head.count == 10 else { return nil }
        var start = 0
        let hb = [UInt8](head)
        if hb[0] == 0x49, hb[1] == 0x44, hb[2] == 0x33 {           // skip ID3v2
            start = ID3Tag.totalSize(header: hb)
        }
        try? h.seek(toOffset: UInt64(start))
        guard let d = try? h.read(upToCount: 64 * 1024) else { return nil }
        return classify([UInt8](d))
    }

    static func classify(_ b: [UInt8]) -> MP3TimingCase {
        // find the first plausible MPEG audio layer III frame header
        var p = 0
        while p + 4 <= b.count {
            if b[p] == 0xFF, b[p + 1] & 0xE0 == 0xE0 {
                let version = (b[p + 1] >> 3) & 0x03      // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
                let layer = (b[p + 1] >> 1) & 0x03        // 1 = layer III
                let bitrate = b[p + 2] >> 4, rate = (b[p + 2] >> 2) & 0x03
                if version != 1, layer == 1, bitrate != 0x0F, rate != 0x03 { break }
            }
            p += 1
        }
        guard p + 4 <= b.count else { return .a }
        let mpeg1 = (b[p + 1] >> 3) & 0x03 == 3
        let mono = (b[p + 3] >> 6) == 3
        let xingOff = p + 4 + (mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17))

        if p + 36 + 4 <= b.count, b[(p + 36) ..< (p + 40)].elementsEqual("VBRI".utf8) { return .d }
        guard xingOff + 8 <= b.count else { return .a }
        let tag = String(decoding: b[xingOff ..< xingOff + 4], as: UTF8.self)
        guard tag == "Xing" || tag == "Info" else { return .a }

        // Position of the LAME extension: after the Xing fields that are present.
        let flags = b.be32(xingOff + 4)
        var lame = xingOff + 8
        if flags & 1 != 0 { lame += 4 }      // frames
        if flags & 2 != 0 { lame += 4 }      // bytes
        if flags & 4 != 0 { lame += 100 }    // TOC
        if flags & 8 != 0 { lame += 4 }      // quality
        guard lame + 36 <= b.count else { return .b }
        let enc = b[lame ..< lame + 4]
        if enc.allSatisfy({ $0 == 0 }) { return .b }
        if String(decoding: enc, as: UTF8.self).lowercased() == "lavc" { return .b }
        guard String(decoding: enc, as: UTF8.self).uppercased().hasPrefix("LAME")
                || String(decoding: enc, as: UTF8.self).uppercased().hasPrefix("L3.9") else { return .b }
        // LAME tag CRC-16 (ARC) over the frame up to the CRC field.
        let crcPos = lame + 34
        let stored = UInt16(b[crcPos]) << 8 | UInt16(b[crcPos + 1])
        return crc16(b[p ..< crcPos]) == stored ? .d : .c
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0 ..< 8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }
}

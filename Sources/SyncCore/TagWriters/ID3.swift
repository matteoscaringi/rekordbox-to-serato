import Foundation

struct ID3Frame {
    var id: String
    var flags: [UInt8]
    var body: [UInt8]
}

/// Minimal ID3v2.3 / v2.4 reader/writer. Unknown frames are copied byte-for-byte.
struct ID3Tag {
    var major: UInt8 = 3
    var frames: [ID3Frame] = []

    static func isID3(_ b: [UInt8]) -> Bool { b.count >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 }

    /// Total on-disk size (header + body + optional footer) from a 10-byte header.
    static func totalSize(header b: [UInt8]) -> Int {
        let footer = (b[3] == 4 && b[5] & 0x10 != 0) ? 10 : 0
        return 10 + Int(b.syncsafe32(6)) + footer
    }

    private static func isFrameStart(_ b: [UInt8], _ p: Int, _ end: Int) -> Bool {
        if p == end { return true }
        if p > end { return false }
        if b[p] == 0 { return true }   // padding
        guard p + 4 <= end else { return false }
        return b[p ..< p + 4].allSatisfy { (0x41 ... 0x5A).contains($0) || (0x30 ... 0x39).contains($0) }
    }

    static func parse(_ b: [UInt8]) throws -> ID3Tag {
        guard isID3(b) else { throw SyncError.corrupt("missing ID3 header") }
        let major = b[3]
        guard major == 3 || major == 4 else { throw SyncError.unsupported("ID3v2.\(major) tag (only v2.3/v2.4)") }
        let flags = b[5]
        if major == 3 && flags & 0x80 != 0 { throw SyncError.unsupported("unsynchronised ID3v2.3 tag") }
        let end = 10 + Int(b.syncsafe32(6))
        guard end <= b.count else { throw SyncError.corrupt("ID3 tag larger than file") }
        var p = 10
        if flags & 0x40 != 0 {
            guard p + 4 <= end else { throw SyncError.corrupt("ID3 extended header") }
            p += major == 4 ? Int(b.syncsafe32(p)) : Int(b.be32(p)) + 4
        }
        var tag = ID3Tag(major: major)
        while p + 10 <= end, b[p] != 0 {
            guard isFrameStart(b, p, end) else { break }
            var size = major == 4 ? Int(b.syncsafe32(p + 4)) : Int(b.be32(p + 4))
            if major == 4 {
                // Some taggers (old iTunes) wrote v2.4 sizes without syncsafe encoding.
                let raw = Int(b.be32(p + 4))
                if raw != size, !isFrameStart(b, p + 10 + size, end), isFrameStart(b, p + 10 + raw, end) { size = raw }
            }
            guard p + 10 + size <= end else { throw SyncError.corrupt("ID3 frame overflows tag") }
            tag.frames.append(ID3Frame(id: b.latin1(p, 4), flags: [b[p + 8], b[p + 9]],
                                       body: Array(b[p + 10 ..< p + 10 + size])))
            p += 10 + size
        }
        return tag
    }

    static func geobDescription(_ body: [UInt8]) -> String? {
        guard body.count > 2 else { return nil }
        let enc = body[0]
        var p = 1
        while p < body.count, body[p] != 0 { p += 1 }
        p += 1 // MIME terminator
        if enc == 0 || enc == 3 {
            while p < body.count, body[p] != 0 { p += 1 }
            p += 1 // filename terminator
            let s = p
            while p < body.count, body[p] != 0 { p += 1 }
            guard s <= p, p <= body.count else { return nil }
            return enc == 0 ? body.latin1(s, p - s) : String(decoding: body[s ..< p], as: UTF8.self)
        }
        func skipUTF16() -> Range<Int> {
            let s = p
            while p + 1 < body.count, !(body[p] == 0 && body[p + 1] == 0) { p += 2 }
            let r = s ..< min(p, body.count); p += 2; return r
        }
        _ = skipUTF16()
        let r = skipUTF16()
        var units: [UInt16] = []
        var i = r.lowerBound
        var bigEndian = enc == 2
        if r.count >= 2, enc == 1 {
            if body[i] == 0xFF && body[i + 1] == 0xFE { bigEndian = false; i += 2 } else if body[i] == 0xFE && body[i + 1] == 0xFF { bigEndian = true; i += 2 }
        }
        while i + 1 < r.upperBound {
            units.append(bigEndian ? UInt16(body[i]) << 8 | UInt16(body[i + 1]) : UInt16(body[i + 1]) << 8 | UInt16(body[i]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    func geob(_ description: String) -> [UInt8]? {
        for f in frames where f.id == "GEOB" && ID3Tag.geobDescription(f.body) == description {
            var p = 1
            for _ in 0 ..< 3 { while p < f.body.count, f.body[p] != 0 { p += 1 }; p += 1 }
            return p <= f.body.count ? Array(f.body[p...]) : nil
        }
        return nil
    }

    mutating func removeGEOB(_ description: String) {
        frames.removeAll { $0.id == "GEOB" && ID3Tag.geobDescription($0.body) == description }
    }

    mutating func setGEOB(_ description: String, _ data: [UInt8]) {
        removeGEOB(description)
        var body: [UInt8] = [0]
        body += Bytes.latin1("application/octet-stream"); body.append(0)
        body.append(0) // empty filename
        body += Bytes.latin1(description); body.append(0)
        body += data
        frames.append(ID3Frame(id: "GEOB", flags: [0, 0], body: body))
    }

    func frameBytes() -> [UInt8] {
        var out: [UInt8] = []
        for f in frames {
            out += Bytes.latin1(f.id)
            if major == 4 { out.appendSyncsafe32(UInt32(f.body.count)) } else { out.appendBE32(UInt32(f.body.count)) }
            out += f.flags
            out += f.body
        }
        return out
    }

    /// Serialises to exactly `totalSize` bytes (header + frames + zero padding).
    func serialize(totalSize: Int) -> [UInt8] {
        let frames = frameBytes()
        precondition(totalSize >= frames.count + 10)
        var out: [UInt8] = [0x49, 0x44, 0x33, major, 0, 0]
        out.appendSyncsafe32(UInt32(totalSize - 10))
        out += frames
        out += [UInt8](repeating: 0, count: totalSize - out.count)
        return out
    }

    /// Applies Serato data: Markers2 replaces Markers_ (v1) so stale v1 cues can't override.
    mutating func applySerato(_ p: SeratoTagPayload) {
        if let m = p.markers2Raw {
            removeGEOB("Serato Markers_")
            setGEOB("Serato Markers2", SeratoTags.markers2ForID3(m))
        }
        if let g = p.beatGridRaw { setGEOB("Serato BeatGrid", g) }
    }
}

enum MP3Writer {
    static func write(_ payload: SeratoTagPayload, to url: URL) throws {
        let f = try AudioFile(url: url)
        var tag = ID3Tag()
        var oldSize = 0
        if f.size >= 10 {
            let head = try f.read(0, 10)
            if ID3Tag.isID3(head) {
                oldSize = ID3Tag.totalSize(header: head)
                guard oldSize <= f.size else { throw SyncError.corrupt("ID3 tag larger than file") }
                tag = try ID3Tag.parse(try f.read(0, oldSize))
            }
        }
        tag.applySerato(payload)
        let needed = tag.frameBytes().count + 10
        if oldSize >= needed {
            try f.write(0, tag.serialize(totalSize: oldSize))
        } else {
            try f.rewrite([.bytes(tag.serialize(totalSize: needed + 4096)),
                           .range(offset: oldSize, length: f.size - oldSize)])
        }
    }

    static func read(_ url: URL) throws -> ID3Tag? {
        let d = [UInt8](try Data(contentsOf: url, options: .alwaysMapped))
        guard ID3Tag.isID3(d) else { return nil }
        return try ID3Tag.parse(Array(d.prefix(ID3Tag.totalSize(header: d))))
    }
}

/// AIFF ("FORM", big-endian) and WAV ("RIFF", little-endian): ID3 tag stored in an "ID3 "/"id3 " chunk.
enum ChunkedID3Writer {
    struct Chunk { var id: String; var offset: Int; var size: Int; var end: Int }

    static func chunks(_ f: AudioFile, littleEndian: Bool) throws -> [Chunk] {
        var out: [Chunk] = []
        var p = 12
        while p + 8 <= f.size {
            let h = try f.read(p, 8)
            let size = Int(littleEndian ? h.le32(4) : h.be32(4))
            let end = min(f.size, p + 8 + size + (size & 1))
            out.append(Chunk(id: h.latin1(0, 4), offset: p, size: size, end: end))
            if p + 8 + size > f.size { break }
            p = end
        }
        return out
    }

    static func write(_ payload: SeratoTagPayload, to url: URL, littleEndian: Bool) throws {
        let f = try AudioFile(url: url)
        guard f.size >= 12 else { throw SyncError.corrupt("file too small") }
        let header = try f.read(0, 12)
        let magic = header.latin1(0, 4)
        guard magic == (littleEndian ? "RIFF" : "FORM") else { throw SyncError.corrupt("not a \(littleEndian ? "WAV" : "AIFF") file") }
        let all = try chunks(f, littleEndian: littleEndian)
        let existing = all.first { $0.id.lowercased() == "id3 " }

        var tag = ID3Tag()
        if let c = existing, c.size >= 10, c.offset + 8 + c.size <= f.size {
            let b = try f.read(c.offset + 8, c.size)
            if ID3Tag.isID3(b) { tag = try ID3Tag.parse(b) }
        }
        tag.applySerato(payload)
        let needed = tag.frameBytes().count + 10

        if let c = existing, c.size >= needed, c.offset + 8 + c.size <= f.size {
            try f.write(c.offset + 8, tag.serialize(totalSize: c.size))
            return
        }
        let newTag = tag.serialize(totalSize: needed + 2048 + (needed & 1))
        var chunk = Bytes.latin1(existing?.id ?? (littleEndian ? "id3 " : "ID3 "))
        if littleEndian { chunk.appendLE32(UInt32(newTag.count)) } else { chunk.appendBE32(UInt32(newTag.count)) }
        chunk += newTag

        var segments: [AudioFile.Segment] = []
        var length = 12
        if let c = existing {
            segments.append(.range(offset: 12, length: c.offset - 12))
            segments.append(.range(offset: c.end, length: f.size - c.end))
            length += (c.offset - 12) + (f.size - c.end)
        } else {
            segments.append(.range(offset: 12, length: f.size - 12))
            length += f.size - 12
        }
        if length & 1 == 1 { segments.append(.bytes([0])); length += 1 }
        segments.append(.bytes(chunk))
        length += chunk.count

        var newHeader = Array(header[0 ..< 4])
        if littleEndian { newHeader.appendLE32(UInt32(length - 8)) } else { newHeader.appendBE32(UInt32(length - 8)) }
        newHeader += header[8 ..< 12]
        try f.rewrite([.bytes(newHeader)] + segments)
    }

    static func read(_ url: URL, littleEndian: Bool) throws -> ID3Tag? {
        let f = try AudioFile(url: url)
        guard let c = try chunks(f, littleEndian: littleEndian).first(where: { $0.id.lowercased() == "id3 " }) else { return nil }
        return try ID3Tag.parse(try f.read(c.offset + 8, c.size))
    }
}

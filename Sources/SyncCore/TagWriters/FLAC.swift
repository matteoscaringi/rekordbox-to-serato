import Foundation

enum FLACWriter {
    static let markersKey = "SERATO_MARKERS_V2"
    static let gridKey = "SERATO_BEATGRID"

    struct Block { var type: UInt8; var data: [UInt8] }

    static func readBlocks(_ f: AudioFile) throws -> (blocks: [Block], metaEnd: Int) {
        guard f.size >= 8, try f.read(0, 4) == Array("fLaC".utf8) else { throw SyncError.corrupt("not a FLAC file") }
        var p = 4
        var blocks: [Block] = []
        while true {
            let h = try f.read(p, 4)
            let len = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
            blocks.append(Block(type: h[0] & 0x7F, data: try f.read(p + 4, len)))
            p += 4 + len
            if h[0] & 0x80 != 0 { break }
        }
        return (blocks, p)
    }

    static func parseComments(_ d: [UInt8]) throws -> (vendor: [UInt8], comments: [String]) {
        guard d.count >= 8 else { throw SyncError.corrupt("vorbis comment block") }
        let vlen = Int(d.le32(0))
        guard 4 + vlen + 4 <= d.count else { throw SyncError.corrupt("vorbis vendor") }
        let vendor = Array(d[4 ..< 4 + vlen])
        var p = 4 + vlen
        let count = Int(d.le32(p)); p += 4
        var comments: [String] = []
        for _ in 0 ..< count {
            guard p + 4 <= d.count else { throw SyncError.corrupt("vorbis comment") }
            let l = Int(d.le32(p)); p += 4
            guard p + l <= d.count else { throw SyncError.corrupt("vorbis comment length") }
            comments.append(String(decoding: d[p ..< p + l], as: UTF8.self)); p += l
        }
        return (vendor, comments)
    }

    static func buildComments(vendor: [UInt8], comments: [String]) -> [UInt8] {
        var o: [UInt8] = []
        o.appendLE32(UInt32(vendor.count)); o += vendor
        o.appendLE32(UInt32(comments.count))
        for c in comments { let u = Array(c.utf8); o.appendLE32(UInt32(u.count)); o += u }
        return o
    }

    static func write(_ payload: SeratoTagPayload, to url: URL) throws {
        let f = try AudioFile(url: url)
        let (blocks, metaEnd) = try readBlocks(f)

        var vendor = Array("rekordbox-to-serato".utf8)
        var comments: [String] = []
        if let vc = blocks.first(where: { $0.type == 4 }) { (vendor, comments) = try parseComments(vc.data) }
        func set(_ key: String, _ value: String) {
            comments.removeAll { $0.uppercased().hasPrefix(key + "=") }
            comments.append("\(key)=\(value)")
        }
        if let m = payload.markers2Raw {
            comments.removeAll { $0.uppercased().hasPrefix("SERATO_MARKERS=") }
            set(markersKey, SeratoTags.base64Envelope(description: "Serato Markers2", payload: SeratoTags.markers2Encoded(m)))
        }
        if let g = payload.beatGridRaw {
            set(gridKey, SeratoTags.base64Envelope(description: "Serato BeatGrid", payload: g))
        }
        let vc = Block(type: 4, data: buildComments(vendor: vendor, comments: comments))

        var out: [Block] = []
        var placed = false
        for b in blocks where b.type != 1 {
            if b.type == 4 { if !placed { out.append(vc); placed = true }; continue }
            out.append(b)
            if b.type == 0 && !placed && !blocks.contains(where: { $0.type == 4 }) { out.append(vc); placed = true }
        }
        if !placed { out.append(vc) }
        guard out.allSatisfy({ $0.data.count < 1 << 24 }) else { throw SyncError.unsupported("FLAC metadata block too large") }

        let used = out.reduce(0) { $0 + 4 + $1.data.count }
        let oldMeta = metaEnd - 4
        var inPlace = false
        if used == oldMeta { inPlace = true } else if used + 4 <= oldMeta {
            out.append(Block(type: 1, data: [UInt8](repeating: 0, count: oldMeta - used - 4))); inPlace = true
        } else {
            out.append(Block(type: 1, data: [UInt8](repeating: 0, count: 4096)))
        }

        var meta = Array("fLaC".utf8)
        for (i, b) in out.enumerated() {
            meta.append(b.type | (i == out.count - 1 ? 0x80 : 0))
            meta += [UInt8((b.data.count >> 16) & 0xFF), UInt8((b.data.count >> 8) & 0xFF), UInt8(b.data.count & 0xFF)]
            meta += b.data
        }
        if inPlace {
            try f.write(0, meta)
        } else {
            try f.rewrite([.bytes(meta), .range(offset: metaEnd, length: f.size - metaEnd)])
        }
    }

    static func readComments(_ url: URL) throws -> [String] {
        let f = try AudioFile(url: url)
        guard let vc = try readBlocks(f).blocks.first(where: { $0.type == 4 }) else { return [] }
        return try parseComments(vc.data).comments
    }
}

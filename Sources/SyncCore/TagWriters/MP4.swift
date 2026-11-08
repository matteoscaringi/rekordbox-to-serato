import Foundation

/// Atom tree for the `moov` box. Unknown atoms are kept byte-for-byte.
final class MP4Atom {
    var typeBytes: [UInt8]
    var prefix: [UInt8] = []          // 4-byte version/flags of `meta`
    var payload: [UInt8] = []
    var children: [MP4Atom]?
    var trailer: [UInt8] = []         // stray bytes after the last child (e.g. udta terminator)
    var large = false

    var type: String { typeBytes.latin1(0, 4) }

    init(_ type: String, payload: [UInt8] = [], children: [MP4Atom]? = nil) {
        typeBytes = Bytes.latin1(type); self.payload = payload; self.children = children
    }
    init(typeBytes: [UInt8]) { self.typeBytes = typeBytes }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "edts", "dinf", "ilst", "----", "meta"]

    static func parse(_ b: [UInt8], _ start: Int, _ end: Int) throws -> (atoms: [MP4Atom], trailer: [UInt8]) {
        var out: [MP4Atom] = []
        var p = start
        while p + 8 <= end {
            var size = Int(b.be32(p))
            var hdr = 8
            var large = false
            if size == 1 {
                guard p + 16 <= end else { throw SyncError.corrupt("mp4 atom header") }
                size = Int(b.be64(p + 8)); hdr = 16; large = true
            } else if size == 0 { size = end - p }
            guard size >= hdr, p + size <= end else { throw SyncError.corrupt("mp4 atom size") }
            let a = MP4Atom(typeBytes: Array(b[p + 4 ..< p + 8]))
            a.large = large
            let cs = p + hdr, ce = p + size
            var parsed = false
            if containers.contains(a.type) {
                do {
                    var s = cs
                    var pre: [UInt8] = []
                    if a.type == "meta", ce - cs >= 4, !(ce - cs >= 8 && b.latin1(cs + 4, 4) == "hdlr") {
                        pre = Array(b[cs ..< cs + 4]); s += 4
                    }
                    let (kids, trailer) = try parse(b, s, ce)
                    a.prefix = pre; a.children = kids; a.trailer = trailer
                    parsed = true
                } catch { parsed = false }
            }
            if !parsed { a.payload = Array(b[cs ..< ce]) }
            out.append(a)
            p += size
        }
        return (out, Array(b[p ..< end]))
    }

    func serialize() -> [UInt8] {
        var content = prefix
        if let children { for c in children { content += c.serialize() } } else { content += payload }
        content += trailer
        var o: [UInt8] = []
        if large || content.count + 8 > Int(UInt32.max) {
            o.appendBE32(1); o += typeBytes; o.appendBE64(UInt64(content.count + 16))
        } else {
            o.appendBE32(UInt32(content.count + 8)); o += typeBytes
        }
        return o + content
    }

    func child(_ t: String) -> MP4Atom? { children?.first { $0.type == t } }

    func all(_ t: String) -> [MP4Atom] {
        (type == t ? [self] : []) + (children ?? []).flatMap { $0.all(t) }
    }
}

enum MP4Writer {
    static let mean = "com.serato.dj"

    struct TopAtom { var type: String; var offset: Int; var size: Int; var hdr: Int }

    static func topLevel(_ f: AudioFile) throws -> [TopAtom] {
        var out: [TopAtom] = []
        var p = 0
        while p + 8 <= f.size {
            let h = try f.read(p, 8)
            var size = Int(h.be32(0)); var hdr = 8
            if size == 1 { size = Int(try f.read(p + 8, 8).be64(0)); hdr = 16 } else if size == 0 { size = f.size - p }
            guard size >= hdr, p + size <= f.size else { throw SyncError.corrupt("mp4 top-level atom") }
            out.append(TopAtom(type: h.latin1(4, 4), offset: p, size: size, hdr: hdr))
            p += size
        }
        return out
    }

    static func freeform(name: String, value: String) -> MP4Atom {
        MP4Atom("----", children: [
            MP4Atom("mean", payload: [0, 0, 0, 0] + Array(mean.utf8)),
            MP4Atom("name", payload: [0, 0, 0, 0] + Array(name.utf8)),
            MP4Atom("data", payload: [0, 0, 0, 1, 0, 0, 0, 0] + Array(value.utf8)),
        ])
    }

    static func freeformName(_ a: MP4Atom) -> String? {
        guard a.type == "----", let m = a.child("mean"), let n = a.child("name"),
              m.payload.count >= 4, n.payload.count >= 4,
              String(decoding: m.payload.dropFirst(4), as: UTF8.self) == mean else { return nil }
        return String(decoding: n.payload.dropFirst(4), as: UTF8.self)
    }

    static func ilst(in moov: MP4Atom, create: Bool) -> MP4Atom? {
        var udta = moov.child("udta")
        if udta == nil, create { udta = MP4Atom("udta", children: []); moov.children?.append(udta!) }
        guard let udta else { return nil }
        if udta.children == nil { return nil }
        var meta = udta.child("meta")
        if meta == nil, create {
            let hdlr = MP4Atom("hdlr", payload: [0, 0, 0, 0, 0, 0, 0, 0] + Bytes.latin1("mdirappl") + [UInt8](repeating: 0, count: 9))
            meta = MP4Atom("meta", children: [hdlr]); meta!.prefix = [0, 0, 0, 0]
            udta.children!.insert(meta!, at: 0)
        }
        guard let meta, meta.children != nil else { return nil }
        var ilst = meta.child("ilst")
        if ilst == nil, create { ilst = MP4Atom("ilst", children: []); meta.children!.append(ilst!) }
        return ilst?.children == nil ? nil : ilst
    }

    static func shiftChunkOffsets(_ moov: MP4Atom, by delta: Int) throws {
        for a in moov.all("stco") where a.payload.count >= 8 {
            let n = Int(a.payload.be32(4))
            guard 8 + n * 4 <= a.payload.count else { throw SyncError.corrupt("stco") }
            for i in 0 ..< n {
                let o = 8 + i * 4
                let v = Int(a.payload.be32(o)) + delta
                guard v >= 0, v <= Int(UInt32.max) else { throw SyncError.unsupported("file too large for 32-bit chunk offsets") }
                let bytes = Bytes.be32(UInt32(v))
                a.payload.replaceSubrange(o ..< o + 4, with: bytes)
            }
        }
        for a in moov.all("co64") where a.payload.count >= 8 {
            let n = Int(a.payload.be32(4))
            guard 8 + n * 8 <= a.payload.count else { throw SyncError.corrupt("co64") }
            for i in 0 ..< n {
                let o = 8 + i * 8
                var b: [UInt8] = []; b.appendBE64(UInt64(Int(a.payload.be64(o)) + delta))
                a.payload.replaceSubrange(o ..< o + 8, with: b)
            }
        }
    }

    static func freeAtom(_ size: Int) -> [UInt8] {
        var o = Bytes.be32(UInt32(size)); o += Bytes.latin1("free"); o += [UInt8](repeating: 0, count: size - 8); return o
    }

    static func write(_ payload: SeratoTagPayload, to url: URL) throws {
        let f = try AudioFile(url: url)
        let top = try topLevel(f)
        guard !top.contains(where: { $0.type == "moof" }) else { throw SyncError.unsupported("fragmented MP4") }
        guard let mi = top.firstIndex(where: { $0.type == "moov" }) else { throw SyncError.corrupt("no moov atom") }
        let m = top[mi]
        let moovBytes = try f.read(m.offset, m.size)
        let (parsed, _) = try MP4Atom.parse(moovBytes, 0, moovBytes.count)
        guard let moov = parsed.first, moov.children != nil else { throw SyncError.corrupt("moov") }
        guard let ilst = ilst(in: moov, create: true) else { throw SyncError.unsupported("unusual MP4 metadata layout") }

        var remove: Set<String> = []
        var add: [MP4Atom] = []
        if let mk = payload.markers2Raw {
            remove.formUnion(["markers", "markersv2"])
            add.append(freeform(name: "markersv2", value: SeratoTags.base64Envelope(
                description: "Serato Markers2", payload: SeratoTags.markers2Encoded(mk))))
        }
        if let g = payload.beatGridRaw {
            remove.insert("beatgrid")
            add.append(freeform(name: "beatgrid", value: SeratoTags.base64Envelope(description: "Serato BeatGrid", payload: g)))
        }
        ilst.children!.removeAll { freeformName($0).map(remove.contains) ?? false }
        ilst.children! += add

        var newMoov = moov.serialize()
        let delta = newMoov.count - m.size

        // 1. Absorb the size change into a following `free` atom (no offsets move).
        if mi + 1 < top.count, ["free", "skip"].contains(top[mi + 1].type) {
            let fr = top[mi + 1]
            let newFree = fr.size - delta
            if newFree >= 8, newFree <= Int(UInt32.max) {
                try f.write(m.offset, newMoov + freeAtom(newFree))
                return
            }
        }
        if delta == 0 { try f.write(m.offset, newMoov); return }

        // 2. Rewrite the file, leaving padding for next time, shifting chunk offsets if media follows moov.
        let padding = 2048
        let mediaAfter = top.contains { $0.type == "mdat" && $0.offset > m.offset }
        if mediaAfter {
            try shiftChunkOffsets(moov, by: delta + padding)
            newMoov = moov.serialize()
        }
        let end = m.offset + m.size
        try f.rewrite([.range(offset: 0, length: m.offset), .bytes(newMoov + freeAtom(padding)),
                       .range(offset: end, length: f.size - end)])
    }

    static func readSerato(_ url: URL) throws -> [String: String] {
        let f = try AudioFile(url: url)
        guard let m = try topLevel(f).first(where: { $0.type == "moov" }) else { return [:] }
        let b = try f.read(m.offset, m.size)
        guard let moov = try MP4Atom.parse(b, 0, b.count).atoms.first, let ilst = ilst(in: moov, create: false) else { return [:] }
        var out: [String: String] = [:]
        for a in ilst.children ?? [] {
            if let n = freeformName(a), let d = a.child("data"), d.payload.count >= 8 {
                out[n] = String(decoding: d.payload.dropFirst(8), as: UTF8.self)
            }
        }
        return out
    }
}

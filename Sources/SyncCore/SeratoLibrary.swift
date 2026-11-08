import Foundation

/// Serato's tag/length/value container format used by crates and `database V2`.
enum SeratoTLV {
    static func tag(_ id: String, _ data: [UInt8]) -> [UInt8] {
        var o = Bytes.latin1(id); o.appendBE32(UInt32(data.count)); o.append(contentsOf: data); return o
    }
    static func string(_ id: String, _ s: String) -> [UInt8] { tag(id, Bytes.utf16BE(s)) }

    static func parse(_ b: [UInt8], _ start: Int = 0, _ end: Int? = nil) -> [(id: String, range: Range<Int>)] {
        let end = end ?? b.count
        var out: [(String, Range<Int>)] = []
        var p = start
        while p + 8 <= end {
            let id = b.latin1(p, 4)
            let len = Int(b.be32(p + 4))
            guard p + 8 + len <= end else { break }
            out.append((id, (p + 8) ..< (p + 8 + len)))
            p += 8 + len
        }
        return out
    }
}

public enum SeratoCrate {
    public static func build(trackPaths: [String]) -> [UInt8] {
        var o = SeratoTLV.string("vrsn", "1.0/Serato ScratchLive Crate")
        o += SeratoTLV.tag("osrt", SeratoTLV.string("tvcn", "song") + SeratoTLV.tag("brev", [0]))
        for col in ["song", "artist", "bpm", "key", "album", "length", "comment"] {
            o += SeratoTLV.tag("ovct", SeratoTLV.string("tvcn", col) + SeratoTLV.string("tvcw", "0"))
        }
        for p in trackPaths { o += SeratoTLV.tag("otrk", SeratoTLV.string("ptrk", p)) }
        return o
    }

    public static func readTrackPaths(_ b: [UInt8]) -> [String] {
        SeratoTLV.parse(b).filter { $0.id == "otrk" }.compactMap { t in
            SeratoTLV.parse(b, t.range.lowerBound, t.range.upperBound).first { $0.id == "ptrk" }
                .map { Bytes.decodeUTF16BE(b[$0.range]) }
        }
    }

    static func sanitize(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "%%", with: "%")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasPrefix(".") { r = "_" + r.dropFirst() }
        return r.isEmpty ? "Untitled" : r
    }

    /// ["Rekordbox","House","Deep"] -> "Rekordbox%%House%%Deep.crate"
    public static func fileName(for components: [String]) -> String {
        components.map(sanitize).joined(separator: "%%") + ".crate"
    }

    /// The mount point of the volume holding `path` ("/" or "/Volumes/Name").
    static func volumeRoot(of path: String) -> String {
        let comps = (path as NSString).pathComponents
        if comps.count >= 3, comps[0] == "/", comps[1] == "Volumes" { return "/Volumes/" + comps[2] }
        return "/"
    }

    /// Serato stores track paths relative to the root of the volume that holds the `_Serato_` folder.
    public static func seratoPath(forFile path: String, seratoFolder: URL) -> String? {
        let root = volumeRoot(of: seratoFolder.path)
        if root == "/" { return path.hasPrefix("/") ? String(path.dropFirst()) : path }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }
}

public enum SeratoDatabase {
    public static let fileName = "database V2"

    public static func existingPaths(_ b: [UInt8]) -> Set<String> {
        var out = Set<String>()
        for t in SeratoTLV.parse(b) where t.id == "otrk" {
            if let pf = SeratoTLV.parse(b, t.range.lowerBound, t.range.upperBound).first(where: { $0.id == "pfil" }) {
                out.insert(Bytes.decodeUTF16BE(b[pf.range]).precomposedStringWithCanonicalMapping)
            }
        }
        return out
    }

    static func fields(for t: RBTrack) -> [(String, String)] {
        var f: [(String, String)] = [("tsng", t.title), ("tart", t.artist), ("talb", t.album), ("tgen", t.genre)]
        if t.bpm > 0 { f.append(("tbpm", String(format: "%.2f", t.bpm))) }
        if !t.key.isEmpty { f.append(("tkey", t.key)) }
        if !t.comments.isEmpty { f.append(("tcom", t.comments)) }
        return f.filter { !$0.1.isEmpty }
    }

    /// Adds tracks Serato doesn't know yet and updates the ones it does: title, artist, album,
    /// genre, BPM, key and comment are set from rekordbox. Everything else Serato stores about
    /// a track (play count, analysis, date added, …) is kept.
    public static func upserting(_ existing: [UInt8]?, tracks: [(seratoPath: String, track: RBTrack)])
        -> (bytes: [UInt8], added: Int, updated: Int) {
        var src = existing ?? []
        if src.isEmpty { src = SeratoTLV.string("vrsn", "2.0/Serato Scratch LIVE Database") }
        var wanted: [String: RBTrack] = [:]
        for (p, t) in tracks { wanted[p.precomposedStringWithCanonicalMapping] = t }

        var out: [UInt8] = []
        var seen = Set<String>()
        var updated = 0
        for tag in SeratoTLV.parse(src) {
            let raw = Array(src[(tag.range.lowerBound - 8) ..< tag.range.upperBound])
            guard tag.id == "otrk" else { out += raw; continue }
            let inner = SeratoTLV.parse(src, tag.range.lowerBound, tag.range.upperBound)
            guard let pf = inner.first(where: { $0.id == "pfil" }) else { out += raw; continue }
            let path = Bytes.decodeUTF16BE(src[pf.range]).precomposedStringWithCanonicalMapping
            guard let t = wanted[path] else { out += raw; continue }
            seen.insert(path)
            var desired = Dictionary(uniqueKeysWithValues: fields(for: t))
            var rec: [UInt8] = []
            for f in inner {
                if let v = desired.removeValue(forKey: f.id) {
                    rec += SeratoTLV.string(f.id, v)
                } else {
                    rec += Array(src[(f.range.lowerBound - 8) ..< f.range.upperBound])
                }
            }
            for (k, v) in fields(for: t) where desired[k] != nil { rec += SeratoTLV.string(k, v) }
            let newRec = SeratoTLV.tag("otrk", rec)
            if newRec != raw { updated += 1 }
            out += newRec
        }

        let now = UInt32(Date().timeIntervalSince1970)
        var added = 0
        for (path, t) in tracks {
            let norm = path.precomposedStringWithCanonicalMapping
            guard !seen.contains(norm) else { continue }
            seen.insert(norm)
            var o = SeratoTLV.string("ttyp", t.fileExtension)
            o += SeratoTLV.string("pfil", path)
            for (k, v) in fields(for: t) { o += SeratoTLV.string(k, v) }
            o += SeratoTLV.string("tadd", String(now))
            o += SeratoTLV.tag("uadd", Bytes.be32(now))
            out += SeratoTLV.tag("otrk", o)
            added += 1
        }
        return (out, added, updated)
    }
}

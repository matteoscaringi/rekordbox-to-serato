import Foundation

public struct SeratoTrackInfo: Identifiable {
    public var id: String { seratoPath }
    public var seratoPath: String
    public var absolutePath: String
    public var title = ""
    public var artist = ""
    public var album = ""
    public var genre = ""
    public var bpm = ""
    public var key = ""
}

public final class SeratoCrateNode: Identifiable {
    public let id: String
    public let name: String
    public internal(set) var children: [SeratoCrateNode] = []
    public internal(set) var trackPaths: [String] = []
    public internal(set) var hasCrateFile = false
    init(id: String, name: String) { self.id = id; self.name = name }
}

public struct SeratoLibrary {
    public var root: SeratoCrateNode
    public var tracks: [SeratoTrackInfo]
    public var byPath: [String: SeratoTrackInfo]   // key: NFC serato path

    public func info(for seratoPath: String) -> SeratoTrackInfo? {
        byPath[seratoPath.precomposedStringWithCanonicalMapping]
    }
}

/// Read-only view of a `_Serato_` folder (database V2 + Subcrates).
public enum SeratoLibraryReader {
    public static func absolutePath(seratoPath: String, seratoFolder: URL) -> String {
        let root = SeratoCrate.volumeRoot(of: seratoFolder.path)
        return root == "/" ? "/" + seratoPath : root + "/" + seratoPath
    }

    public static func read(seratoFolder: URL) throws -> SeratoLibrary {
        let fm = FileManager.default
        var tracks: [SeratoTrackInfo] = []
        let dbURL = seratoFolder.appendingPathComponent(SeratoDatabase.fileName)
        if fm.fileExists(atPath: dbURL.path) {
            let b = [UInt8](try Data(contentsOf: dbURL))
            for t in SeratoTLV.parse(b) where t.id == "otrk" {
                var f: [String: String] = [:]
                for field in SeratoTLV.parse(b, t.range.lowerBound, t.range.upperBound)
                    where field.id.hasPrefix("t") || field.id.hasPrefix("p") {
                    f[field.id] = Bytes.decodeUTF16BE(b[field.range])
                }
                guard let p = f["pfil"] else { continue }
                tracks.append(SeratoTrackInfo(
                    seratoPath: p, absolutePath: absolutePath(seratoPath: p, seratoFolder: seratoFolder),
                    title: f["tsng"] ?? "", artist: f["tart"] ?? "", album: f["talb"] ?? "",
                    genre: f["tgen"] ?? "", bpm: f["tbpm"] ?? "", key: f["tkey"] ?? ""))
            }
        }
        var byPath: [String: SeratoTrackInfo] = [:]
        for t in tracks { byPath[t.seratoPath.precomposedStringWithCanonicalMapping] = t }

        let root = SeratoCrateNode(id: "", name: "Crates")
        var nodes: [String: SeratoCrateNode] = ["": root]
        let sub = seratoFolder.appendingPathComponent("Subcrates")
        let files = ((try? fm.contentsOfDirectory(atPath: sub.path)) ?? []).filter { $0.hasSuffix(".crate") }
        for file in files {
            let full = String(file.dropLast(".crate".count))
            let comps = full.components(separatedBy: "%%")
            var parent = root
            var key = ""
            for c in comps {
                key = key.isEmpty ? c : key + "%%" + c
                if let n = nodes[key] { parent = n; continue }
                let n = SeratoCrateNode(id: key, name: c)
                nodes[key] = n
                parent.children.append(n)
                parent = n
            }
            parent.hasCrateFile = true
            if let d = try? Data(contentsOf: sub.appendingPathComponent(file)) {
                parent.trackPaths = SeratoCrate.readTrackPaths([UInt8](d))
            }
        }
        func sort(_ n: SeratoCrateNode) {
            n.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            n.children.forEach(sort)
        }
        sort(root)
        return SeratoLibrary(root: root, tracks: tracks, byPath: byPath)
    }
}

public struct SeratoDecodedMarkers {
    public var cues: [SeratoCue] = []
    public var loops: [SeratoLoop] = []
    public var bpmLock = false
}

extension SeratoTags {
    public static func decodeMarkers(_ raw: [UInt8]) -> SeratoDecodedMarkers {
        var out = SeratoDecodedMarkers()
        func cString(_ d: [UInt8], from i: Int) -> String {
            guard i < d.count else { return "" }
            return String(decoding: d[i...].prefix { $0 != 0 }, as: UTF8.self)
        }
        for e in parseMarkers2Entries(raw) {
            let d = e.data
            switch e.name {
            case "CUE" where d.count >= 12:
                out.cues.append(SeratoCue(index: d[1], positionMs: d.be32(2), color: RGB(d[7], d[8], d[9]),
                                          name: cString(d, from: 12)))
            case "LOOP" where d.count >= 20:
                out.loops.append(SeratoLoop(index: d[1], startMs: d.be32(2), endMs: d.be32(6),
                                            name: cString(d, from: 20), locked: d[19] != 0))
            case "BPMLOCK" where !d.isEmpty:
                out.bpmLock = d[0] != 0
            default: break
            }
        }
        return out
    }

    public static func decodeBeatGrid(_ raw: [UInt8]) -> [SeratoBeatMarker] {
        guard raw.count >= 6 else { return [] }
        let n = Int(raw.be32(2))
        guard n > 0, 6 + n * 8 <= raw.count else { return [] }
        return (0 ..< n).map { i in
            let o = 6 + i * 8
            let pos = Float(bitPattern: raw.be32(o))
            return i == n - 1
                ? SeratoBeatMarker(position: pos, beatsToNext: nil, bpm: Float(bitPattern: raw.be32(o + 4)))
                : SeratoBeatMarker(position: pos, beatsToNext: raw.be32(o + 4), bpm: nil)
        }
    }
}

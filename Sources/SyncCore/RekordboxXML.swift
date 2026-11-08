import Foundation

/// Reads a `rekordbox.xml` export (File ▸ Export Collection in xml format, or the
/// "rekordbox xml" path in Preferences ▸ Advanced). Strictly read-only.
public enum RekordboxXMLParser {
    public static func parse(url: URL) throws -> RBLibrary {
        guard let parser = XMLParser(contentsOf: url) else {
            throw SyncError.io("cannot open \(url.path)")
        }
        let d = Delegate()
        parser.delegate = d
        guard parser.parse() else {
            throw SyncError.corrupt("rekordbox XML: \(parser.parserError?.localizedDescription ?? "parse error")")
        }
        guard d.sawDJPlaylists else { throw SyncError.corrupt("not a rekordbox XML file (no DJ_PLAYLISTS)") }

        let root = d.root ?? RBNode(id: "ROOT", name: "ROOT", isFolder: true)
        var byLocation: [String: String] = [:]
        for t in d.tracks.values { byLocation[t.location] = t.id }
        func resolve(_ n: RBNode) {
            n.trackIDs = n.rawKeys.compactMap { key in
                if n.keyType == 1 { return byLocation[key] }
                return d.tracks[key] != nil ? key : nil
            }
            n.children.forEach(resolve)
        }
        resolve(root)
        return RBLibrary(tracks: d.tracks, trackOrder: d.order, root: root)
    }

    static func filePath(fromLocation loc: String) -> String {
        if let u = URL(string: loc), u.isFileURL, !u.path.isEmpty { return u.path }
        var s = loc
        for p in ["file://localhost", "file://"] where s.hasPrefix(p) { s.removeFirst(p.count); break }
        return s.removingPercentEncoding ?? s
    }

    private static func dbl(_ s: String?) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var tracks: [String: RBTrack] = [:]
        var order: [String] = []
        var current: RBTrack?
        var inCollection = false
        var inPlaylists = false
        var sawDJPlaylists = false
        var stack: [RBNode] = []
        var root: RBNode?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "DJ_PLAYLISTS": sawDJPlaylists = true
            case "COLLECTION": inCollection = true
            case "PLAYLISTS": inPlaylists = true
            case "TRACK":
                if inPlaylists {
                    if let key = a["Key"], let top = stack.last { top.rawKeys.append(key) }
                } else if inCollection, let id = a["TrackID"] {
                    var t = RBTrack(id: id)
                    t.title = a["Name"] ?? ""
                    t.artist = a["Artist"] ?? ""
                    t.album = a["Album"] ?? ""
                    t.genre = a["Genre"] ?? ""
                    t.kind = a["Kind"] ?? ""
                    t.location = a["Location"] ?? ""
                    t.path = RekordboxXMLParser.filePath(fromLocation: t.location)
                    t.bpm = RekordboxXMLParser.dbl(a["AverageBpm"]) ?? 0
                    t.key = a["Tonality"] ?? ""
                    t.totalTime = Int(a["TotalTime"] ?? "") ?? 0
                    t.comments = a["Comments"] ?? ""
                    current = t
                }
            case "TEMPO":
                guard current != nil, let pos = RekordboxXMLParser.dbl(a["Inizio"]),
                      let bpm = RekordboxXMLParser.dbl(a["Bpm"]) else { return }
                current?.tempos.append(RBTempo(position: pos, bpm: bpm, beatInBar: Int(a["Battito"] ?? "1") ?? 1))
            case "POSITION_MARK":
                guard current != nil, let start = RekordboxXMLParser.dbl(a["Start"]) else { return }
                var color: RGB?
                if let r = a["Red"].flatMap({ UInt8($0) }), let g = a["Green"].flatMap({ UInt8($0) }),
                   let b = a["Blue"].flatMap({ UInt8($0) }) {
                    color = RGB(r, g, b)
                }
                current?.marks.append(RBPositionMark(
                    name: a["Name"] ?? "", type: Int(a["Type"] ?? "0") ?? 0, start: start,
                    end: RekordboxXMLParser.dbl(a["End"]), num: Int(a["Num"] ?? "-1") ?? -1, color: color))
            case "NODE":
                guard inPlaylists else { return }
                let isFolder = (a["Type"] ?? "0") == "0"
                let parentID = stack.last?.id ?? ""
                let index = stack.last?.children.count ?? 0
                let node = RBNode(id: "\(parentID)/\(index)", name: a["Name"] ?? "Untitled", isFolder: isFolder)
                node.keyType = Int(a["KeyType"] ?? "0") ?? 0
                if let parent = stack.last { parent.children.append(node) } else { root = node }
                stack.append(node)
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "COLLECTION": inCollection = false
            case "PLAYLISTS": inPlaylists = false
            case "TRACK":
                if inCollection, !inPlaylists, let t = current {
                    if tracks[t.id] == nil { order.append(t.id) }
                    tracks[t.id] = t
                    current = nil
                }
            case "NODE":
                if inPlaylists, !stack.isEmpty { stack.removeLast() }
            default: break
            }
        }
    }
}

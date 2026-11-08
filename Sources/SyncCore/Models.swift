import Foundation

public struct RGB: Hashable, Codable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) { self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF)) }
    public var hex: String { String(format: "%02X%02X%02X", r, g, b) }
    func distance(to o: RGB) -> Int {
        let dr = Int(r) - Int(o.r), dg = Int(g) - Int(o.g), db = Int(b) - Int(o.b)
        return dr * dr + dg * dg + db * db
    }
}

/// One `<TEMPO>` entry of a Rekordbox beatgrid.
public struct RBTempo {
    public var position: Double   // seconds ("Inizio")
    public var bpm: Double
    public var beatInBar: Int     // 1...4 ("Battito")
}

/// One `<POSITION_MARK>` (hot cue, memory cue or loop).
public struct RBPositionMark {
    public var name: String
    public var type: Int          // 0 cue, 1 fade-in, 2 fade-out, 3 load, 4 loop
    public var start: Double      // seconds
    public var end: Double?       // seconds (loops)
    public var num: Int           // -1 = memory cue/loop, 0...7 = hot cue A...H
    public var color: RGB?

    public var isLoop: Bool { type == 4 && (end ?? 0) > start }
    public var isHot: Bool { num >= 0 }
}

public struct RBTrack: Identifiable {
    public var id: String
    public var title = ""
    public var artist = ""
    public var album = ""
    public var genre = ""
    public var kind = ""
    public var location = ""      // raw Location attribute
    public var path = ""          // decoded POSIX path
    public var bpm: Double = 0
    public var key = ""
    public var totalTime = 0
    public var comments = ""
    public var tempos: [RBTempo] = []
    public var marks: [RBPositionMark] = []

    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }
}

public final class RBNode: Identifiable {
    public let id: String
    public let name: String
    public let isFolder: Bool
    public internal(set) var children: [RBNode] = []
    public internal(set) var trackIDs: [String] = []
    var rawKeys: [String] = []
    var keyType = 0

    init(id: String, name: String, isFolder: Bool) {
        self.id = id; self.name = name; self.isFolder = isFolder
    }

    /// For SwiftUI's OutlineGroup: nil for playlists (leaves).
    public var childNodes: [RBNode]? { isFolder ? children : nil }

    public var allPlaylists: [RBNode] {
        isFolder ? children.flatMap { $0.allPlaylists } : [self]
    }
}

public struct RBLibrary {
    public var tracks: [String: RBTrack]
    public var trackOrder: [String]
    public var root: RBNode
    public var playlistCount: Int { root.allPlaylists.count }
}

import Foundation

public struct SeratoTagPayload: Equatable {
    public var markers2Raw: [UInt8]?
    public var beatGridRaw: [UInt8]?
    public init(markers2Raw: [UInt8]?, beatGridRaw: [UInt8]?) {
        self.markers2Raw = markers2Raw; self.beatGridRaw = beatGridRaw
    }
    public var isEmpty: Bool { markers2Raw == nil && beatGridRaw == nil }
}

public enum AudioTagWriter {
    public static let supportedExtensions: Set<String> = ["mp3", "aif", "aiff", "wav", "flac", "m4a", "mp4", "aac", "alac"]

    public static func supports(_ path: String) -> Bool {
        supportedExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func write(_ payload: SeratoTagPayload, to url: URL) throws {
        guard !payload.isEmpty else { return }
        switch url.pathExtension.lowercased() {
        case "mp3": try MP3Writer.write(payload, to: url)
        case "aif", "aiff": try ChunkedID3Writer.write(payload, to: url, littleEndian: false)
        case "wav": try ChunkedID3Writer.write(payload, to: url, littleEndian: true)
        case "flac": try FLACWriter.write(payload, to: url)
        case "m4a", "mp4", "aac", "alac": try MP4Writer.write(payload, to: url)
        default: throw SyncError.unsupported("file type .\(url.pathExtension)")
        }
    }

    /// Reads back the Serato data in a file (verification / tests).
    public static func readSerato(from url: URL) throws -> (markers2: [UInt8]?, beatGrid: [UInt8]?) {
        func fromEnvelope(_ s: String?) -> [UInt8]? {
            guard let s, let d = Data(base64Encoded: s.filter { !$0.isWhitespace }) else { return nil }
            let b = [UInt8](d)
            var p = 0, nulls = 0
            while p < b.count, nulls < 3 { if b[p] == 0 { nulls += 1 }; p += 1 }
            return Array(b[p...])
        }
        switch url.pathExtension.lowercased() {
        case "mp3", "aif", "aiff", "wav":
            let tag: ID3Tag?
            switch url.pathExtension.lowercased() {
            case "mp3": tag = try MP3Writer.read(url)
            case "wav": tag = try ChunkedID3Writer.read(url, littleEndian: true)
            default: tag = try ChunkedID3Writer.read(url, littleEndian: false)
            }
            return (tag?.geob("Serato Markers2").flatMap { SeratoTags.decodeMarkers2(id3Payload: $0) },
                    tag?.geob("Serato BeatGrid"))
        case "flac":
            let c = try FLACWriter.readComments(url)
            func v(_ k: String) -> String? { c.first { $0.uppercased().hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
            return (fromEnvelope(v(FLACWriter.markersKey)).flatMap { SeratoTags.decodeMarkers2(id3Payload: $0) },
                    fromEnvelope(v(FLACWriter.gridKey)))
        default:
            let d = try MP4Writer.readSerato(url)
            return (fromEnvelope(d["markersv2"]).flatMap { SeratoTags.decodeMarkers2(id3Payload: $0) },
                    fromEnvelope(d["beatgrid"]))
        }
    }
}

import Foundation

public enum SyncError: LocalizedError {
    case unsupported(String)
    case corrupt(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "Unsupported: \(s)"
        case .corrupt(let s): return "Corrupt or unexpected data: \(s)"
        case .io(let s): return "I/O error: \(s)"
        }
    }
}

extension Array where Element == UInt8 {
    func be16(_ o: Int) -> UInt16 { UInt16(self[o]) << 8 | UInt16(self[o + 1]) }
    func be32(_ o: Int) -> UInt32 {
        UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }
    func le32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func be64(_ o: Int) -> UInt64 { UInt64(be32(o)) << 32 | UInt64(be32(o + 4)) }
    func syncsafe32(_ o: Int) -> UInt32 {
        (UInt32(self[o]) & 0x7F) << 21 | (UInt32(self[o + 1]) & 0x7F) << 14
            | (UInt32(self[o + 2]) & 0x7F) << 7 | (UInt32(self[o + 3]) & 0x7F)
    }
    /// Latin-1 decode (lossless for 4-char codes).
    func latin1(_ o: Int, _ n: Int) -> String {
        String(self[o ..< o + n].map { Character(Unicode.Scalar($0)) })
    }

    mutating func appendBE16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func appendBE32(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    mutating func appendLE32(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
    mutating func appendBE64(_ v: UInt64) { appendBE32(UInt32(v >> 32)); appendBE32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func appendSyncsafe32(_ v: UInt32) {
        append(contentsOf: [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)])
    }
    mutating func appendFloatBE(_ f: Float) { appendBE32(f.bitPattern) }
    mutating func appendLatin1(_ s: String) {
        append(contentsOf: s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") })
    }
}

enum Bytes {
    static func latin1(_ s: String) -> [UInt8] { var a: [UInt8] = []; a.appendLatin1(s); return a }
    static func utf16BE(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf16.count * 2)
        for u in s.utf16 { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
        return out
    }
    static func decodeUTF16BE(_ b: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        var i = b.startIndex
        while i + 1 < b.endIndex { units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])); i += 2 }
        return String(decoding: units, as: UTF16.self)
    }
    static func be32(_ v: UInt32) -> [UInt8] { var a: [UInt8] = []; a.appendBE32(v); return a }
}

/// Random-access file wrapper used by the tag writers so that small in-place
/// updates never need to load or rewrite the whole audio file.
final class AudioFile {
    let url: URL
    let handle: FileHandle
    let size: Int

    init(url: URL) throws {
        self.url = url
        do { handle = try FileHandle(forUpdating: url) } catch {
            throw SyncError.io("cannot open \(url.lastPathComponent) for writing: \(error.localizedDescription)")
        }
        size = Int(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    func read(_ offset: Int, _ count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= size else { throw SyncError.corrupt("read past end of file") }
        if count == 0 { return [] }
        try handle.seek(toOffset: UInt64(offset))
        let d = try handle.read(upToCount: count) ?? Data()
        guard d.count == count else { throw SyncError.corrupt("unexpected end of file") }
        return [UInt8](d)
    }

    func write(_ offset: Int, _ bytes: [UInt8]) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(bytes))
        try handle.synchronize()
    }

    enum Segment {
        case bytes([UInt8])
        case range(offset: Int, length: Int)
    }

    /// Builds a new file from segments (new bytes and ranges of the original)
    /// in a temp file next to the original, then atomically swaps it in.
    func rewrite(_ segments: [Segment]) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).rb2serato.tmp")
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw SyncError.io("cannot create temp file in \(dir.path)")
        }
        do {
            let out = try FileHandle(forWritingTo: tmp)
            defer { try? out.close() }
            for seg in segments {
                switch seg {
                case .bytes(let b):
                    try out.write(contentsOf: Data(b))
                case .range(let offset, let length):
                    guard offset >= 0, length >= 0, offset + length <= size else {
                        throw SyncError.corrupt("invalid copy range")
                    }
                    try handle.seek(toOffset: UInt64(offset))
                    var remaining = length
                    while remaining > 0 {
                        let n = Swift.min(remaining, 4 << 20)
                        guard let d = try handle.read(upToCount: n), d.count == n else {
                            throw SyncError.corrupt("unexpected end of file while copying")
                        }
                        try out.write(contentsOf: d)
                        remaining -= n
                    }
                }
            }
            try out.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

import Foundation

/// Maps a path from rekordbox to the exact spelling stored on disk.
///
/// macOS volumes are normalization-insensitive (and usually case-insensitive), so
/// "Beyoncé" written as NFC (rekordbox XML) and NFD (on disk) open the same file.
/// Serato however compares paths as strings, so a different spelling would show up
/// as a second, duplicate track. Using the on-disk spelling makes Serato point at
/// the very same file entry it would get by scanning the folder itself.
public final class OnDiskPathResolver {
    private var cache: [String: (exact: [String: String], folded: [String: String])] = [:]

    public init() {}

    public func resolve(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var current = "/"
        for comp in (path as NSString).pathComponents.dropFirst() {
            let m = listing(current)
            let actual = m.exact[comp.precomposedStringWithCanonicalMapping] ?? m.folded[Self.fold(comp)] ?? comp
            current = (current as NSString).appendingPathComponent(actual)
        }
        return current
    }

    static func fold(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    private func listing(_ dir: String) -> (exact: [String: String], folded: [String: String]) {
        if let c = cache[dir] { return c }
        var exact: [String: String] = [:], folded: [String: String] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            exact[n.precomposedStringWithCanonicalMapping] = n
            if folded[Self.fold(n)] == nil { folded[Self.fold(n)] = n }
        }
        cache[dir] = (exact, folded)
        return (exact, folded)
    }
}

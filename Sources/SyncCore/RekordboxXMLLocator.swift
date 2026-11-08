import Foundation

/// What rekordbox's own preferences say about XML files (read-only).
public struct RekordboxSettings {
    /// rekordbox 7 "automatic collection XML export".
    public var autoExportEnabled = false
    public var autoExportFile: String?
    /// Preferences ▸ Advanced ▸ Database ▸ rekordbox xml ("Imported Library").
    public var importedLibraryFile: String?

    /// Reads `~/Library/Application Support/Pioneer/<version>/rekordbox3.settings`.
    public static func read(home: URL) -> RekordboxSettings? {
        let pioneer = home.appendingPathComponent("Library/Application Support/Pioneer")
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(atPath: pioneer.path)) ?? [])
            .filter { $0.hasPrefix("rekordbox") }
            .map { pioneer.appendingPathComponent($0).appendingPathComponent("rekordbox3.settings") }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { modDate($0) > modDate($1) }   // the one rekordbox wrote last
        guard let file = candidates.first, let parser = XMLParser(contentsOf: file) else { return nil }
        let d = ValueCollector()
        parser.delegate = d
        guard parser.parse() else { return nil }
        func path(_ k: String) -> String? { d.values[k].flatMap { $0.isEmpty ? nil : $0 } }
        return RekordboxSettings(autoExportEnabled: d.values["CollectionAutoExportEnable"] == "1",
                                 autoExportFile: path("CollectionAutoExportXmlFile"),
                                 importedLibraryFile: path("bridgeImportedLibraryFile"))
    }

    private final class ValueCollector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            if name == "VALUE", let n = a["name"], let v = a["val"] { values[n] = v }
        }
    }
}

func modDate(_ url: URL) -> Date {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
}

public struct RekordboxXMLCandidate: Equatable {
    public enum Source: String {
        case autoExport = "rekordbox automatic export"
        case rekordboxSetting = "rekordbox's XML setting"
        case usualLocation = "usual location"
        case spotlight = "Spotlight"
    }
    public let url: URL
    public let source: Source
    public let modified: Date
}

/// Finds rekordbox collection exports without the user having to browse for them.
public enum RekordboxXMLLocator {
    /// Cheap content check: a rekordbox collection export starts with DJ_PLAYLISTS and a rekordbox PRODUCT.
    public static func isRekordboxXML(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "xml",
              let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = String(decoding: (try? h.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return head.contains("<DJ_PLAYLISTS") && head.range(of: "Name=\"rekordbox\"", options: .caseInsensitive) != nil
    }

    static func usualLocations(home: URL) -> [URL] {
        let names = ["rekordbox.xml", "Rekordbox.xml", "rekordbox collection.xml", "collection.xml"]
        let dirs = ["Documents", "Desktop", "Music", "Downloads", "Music/rekordbox", "Documents/rekordbox",
                    "Library/rekordbox/rekordbox", "Library/Pioneer/rekordbox"]
        return dirs.flatMap { d in names.map { home.appendingPathComponent(d).appendingPathComponent($0) } }
    }

    static func spotlight(home: URL) -> [URL] {
        func mdfind(_ query: String) -> [URL] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["-onlyin", home.path, query]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
        let byName = mdfind(#"kMDItemFSName == "*.xml"c && kMDItemFSName == "*rekordbox*"c"#)
        let byContent = mdfind(#"kMDItemFSName == "*.xml"c && kMDItemTextContent == "DJ_PLAYLISTS""#)
        return byName + byContent
    }

    /// All valid rekordbox XML files found, best first.
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  useSpotlight: Bool = true) -> [RekordboxXMLCandidate] {
        var out: [RekordboxXMLCandidate] = []
        var seen = Set<String>()
        func add(_ url: URL, _ source: RekordboxXMLCandidate.Source) {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            guard !seen.contains(key), isRekordboxXML(url) else { return }
            seen.insert(key)
            out.append(RekordboxXMLCandidate(url: url, source: source, modified: modDate(url)))
        }
        let settings = RekordboxSettings.read(home: home)
        if let p = settings?.autoExportFile { add(URL(fileURLWithPath: (p as NSString).expandingTildeInPath), .autoExport) }
        if let p = settings?.importedLibraryFile { add(URL(fileURLWithPath: (p as NSString).expandingTildeInPath), .rekordboxSetting) }
        usualLocations(home: home).forEach { add($0, .usualLocation) }
        if useSpotlight { spotlight(home: home).forEach { add($0, .spotlight) } }

        // rekordbox's automatic export is always current, so it wins; otherwise the newest export.
        return out.sorted {
            if ($0.source == .autoExport) != ($1.source == .autoExport) { return $0.source == .autoExport }
            return $0.modified > $1.modified
        }
    }

    public static func best(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            useSpotlight: Bool = true) -> RekordboxXMLCandidate? {
        candidates(home: home, useSpotlight: useSpotlight).first
    }
}

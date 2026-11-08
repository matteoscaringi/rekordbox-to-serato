// Real-file test: `swift run SyncSelfTest --real <list.txt> <empty work dir>`
// <list.txt> holds one original audio path per line. Originals are only READ:
// each is copied into the work dir, the copy is tagged, and the copy is compared
// against the original (decoded audio via Core Audio and ffmpeg, plus all metadata).
import CryptoKit
import Foundation
@testable import SyncCore

private func run(_ args: [String]) -> (status: Int32, out: Data, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = (env["PATH"] ?? "") + ":" + NSHomeDirectory() + "/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin"
    p.environment = env
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return (-1, Data(), "\(error)") }
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, od, String(decoding: ed, as: UTF8.self))
}

/// SHA-256 of the decoded PCM ("data" chunk) produced by Core Audio (afconvert → WAV float32).
/// Streams the data so even hour-long mixes don't need to fit in memory.
private func coreAudioPCM(_ path: String, tmp: URL) -> String? {
    let out = tmp.appendingPathComponent("ca-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: out) }
    guard run(["afconvert", "-f", "WAVE", "-d", "LEF32", path, out.path]).status == 0,
          let f = try? AudioFile(url: out) else { return nil }
    var p = 12
    while p + 8 <= f.size {
        guard let h = try? f.read(p, 8) else { return nil }
        let id = h.latin1(0, 4), size = Int(h.le32(4))
        if id == "data" {
            var hasher = SHA256()
            var off = p + 8
            let end = min(f.size, p + 8 + size)
            while off < end {
                let n = min(8 << 20, end - off)
                guard let chunk = try? f.read(off, n) else { return nil }
                hasher.update(data: Data(chunk))
                off += n
            }
            return "\(end - p - 8) bytes " + hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        p += 8 + size + (size & 1)
    }
    return nil
}

private func ffmpegMD5(_ path: String) -> String? {
    let r = run(["ffmpeg", "-v", "error", "-i", path, "-map", "0:a:0", "-f", "md5", "-"])
    guard r.status == 0, r.err.isEmpty else { return nil }
    return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func ffprobeInfo(_ path: String) -> (tags: [String: String], duration: String, errors: String)? {
    let r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration:format_tags:stream_tags", "-of", "json", path])
    guard r.status == 0,
          let j = try? JSONSerialization.jsonObject(with: r.out) as? [String: Any],
          let f = j["format"] as? [String: Any] else { return nil }
    var tags: [String: String] = [:]
    for (k, v) in (f["tags"] as? [String: Any]) ?? [:] where !k.lowercased().contains("serato") && !["markersv2", "markers", "beatgrid"].contains(k.lowercased()) { tags[k] = "\(v)" }
    return (tags, "\(f["duration"] ?? "?")", r.err)
}

private let seratoGEOBs: Set<String> = ["Serato Markers2", "Serato BeatGrid", "Serato Markers_"]

/// Everything in the file's own metadata except Serato's entries, as comparable strings.
private func nonSeratoMetadata(_ url: URL) throws -> [String] {
    switch url.pathExtension.lowercased() {
    case "mp3", "aif", "aiff", "wav":
        let tag: ID3Tag?
        switch url.pathExtension.lowercased() {
        case "mp3": tag = try MP3Writer.read(url)
        case "wav": tag = try ChunkedID3Writer.read(url, littleEndian: true)
        default: tag = try ChunkedID3Writer.read(url, littleEndian: false)
        }
        return (tag?.frames ?? []).filter {
            !($0.id == "GEOB" && seratoGEOBs.contains(ID3Tag.geobDescription($0.body) ?? ""))
        }.map { "\($0.id):\($0.body.count):\(Data($0.body).base64EncodedString().prefix(64))\(Data($0.body).hashValue)" }
    case "flac":
        let f = try AudioFile(url: url)
        let blocks = try FLACWriter.readBlocks(f).blocks
        var out: [String] = []
        for b in blocks where b.type != 1 {
            if b.type == 4 {
                out += try FLACWriter.parseComments(b.data).comments.filter { !$0.uppercased().hasPrefix("SERATO_") }
            } else {
                out.append("block\(b.type):\(b.data.count):\(Data(b.data).hashValue)")
            }
        }
        return out
    default:
        let f = try AudioFile(url: url)
        guard let m = try MP4Writer.topLevel(f).first(where: { $0.type == "moov" }) else { return [] }
        let b = try f.read(m.offset, m.size)
        guard let moov = try MP4Atom.parse(b, 0, b.count).atoms.first,
              let ilst = MP4Writer.ilst(in: moov, create: false) else { return [] }
        return (ilst.children ?? []).filter { MP4Writer.freeformName($0) == nil }.map { Data($0.serialize()).base64EncodedString() }
    }
}

private func realisticTrack(variant: Int) -> RBTrack {
    var t = RBTrack(id: "x")
    let colors = [RGB(40, 226, 20), RGB(222, 68, 207), RGB(48, 90, 255), RGB(255, 140, 0)]
    for i in 0 ..< 8 where variant == 0 || i % 2 == 0 {
        t.marks.append(RBPositionMark(name: variant == 0 ? "Cue \(i + 1) – Drop 🔥 ünï" : "", type: 0,
                                      start: 4.25 + Double(i) * 15.003, end: nil, num: i, color: colors[i % 4]))
    }
    t.marks.append(RBPositionMark(name: "Loop", type: 4, start: 64, end: 71.5, num: -1, color: nil))
    t.marks.append(RBPositionMark(name: "", type: 4, start: 96, end: 97.875, num: -1, color: nil))
    t.marks.append(RBPositionMark(name: "Memory", type: 0, start: 150.2, end: nil, num: -1, color: nil))
    t.tempos = variant == 0
        ? [RBTempo(position: 0.043, bpm: 126, beatInBar: 1), RBTempo(position: 60.0430, bpm: 126.5, beatInBar: 1),
           RBTempo(position: 120.2, bpm: 128, beatInBar: 2)]
        : [RBTempo(position: 0.112, bpm: 124.98, beatInBar: 4)]
    return t
}

private func payload(_ t: RBTrack) -> SeratoTagPayload {
    let r = Converter.cuesAndLoops(for: t, options: ConversionOptions())
    return SeratoTagPayload(markers2Raw: SeratoTags.markers2Raw(cues: r.cues, loops: r.loops, bpmLock: true),
                            beatGridRaw: SeratoTags.beatGridRaw(Converter.beatGrid(for: t)))
}

func runRealFileTest(listFile: String, work: URL) -> Int32 {
    let fm = FileManager.default
    let originals = ((try? String(contentsOfFile: listFile, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
    var failedFiles: [String] = []

    for (n, orig) in originals.enumerated() {
        let name = (orig as NSString).lastPathComponent
        print("[\(n + 1)/\(originals.count)] \(name)")
        var problems: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }

        let origAttrs = try? fm.attributesOfItem(atPath: orig)
        let origMod = origAttrs?[.modificationDate] as? Date
        let dir = work.appendingPathComponent("\(n)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(name)
        do { try fm.copyItem(atPath: orig, toPath: copy.path) } catch { print("  ✗ copy failed: \(error)"); failedFiles.append(name); continue }

        let refPCM = coreAudioPCM(orig, tmp: work)
        let refMD5 = ffmpegMD5(orig)
        let refProbe = ffprobeInfo(orig)
        let refMeta = try? nonSeratoMetadata(URL(fileURLWithPath: orig))
        let size0 = (try? fm.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? 0
        if refPCM == nil { print("  (Core Audio can't decode the original; skipping that comparison)") }
        if refMD5 == nil { print("  (ffmpeg reported errors on the ORIGINAL; skipping ffmpeg comparison)") }

        let payloads = [payload(realisticTrack(variant: 0)), payload(realisticTrack(variant: 0)), payload(realisticTrack(variant: 1))]
        var sizes: [Int] = []
        for (i, p) in payloads.enumerated() {
            do {
                try AudioTagWriter.write(p, to: copy)
                let back = try AudioTagWriter.readSerato(from: copy)
                check(back.markers2 == p.markers2Raw, "pass \(i + 1): cues not read back identically")
                check(back.beatGrid == p.beatGridRaw, "pass \(i + 1): beatgrid not read back identically")
                let dec = SeratoTags.decodeMarkers(back.markers2 ?? [])
                check(dec.cues.count == Converter.cuesAndLoops(for: realisticTrack(variant: i == 2 ? 1 : 0), options: ConversionOptions()).cues.count,
                      "pass \(i + 1): decoded cue count")
            } catch { problems.append("pass \(i + 1): \(error.localizedDescription)") }
            sizes.append((try? fm.attributesOfItem(atPath: copy.path)[.size] as? Int) ?? 0)
        }

        if let refPCM {
            let got = coreAudioPCM(copy.path, tmp: work)
            if got != refPCM, let again = coreAudioPCM(orig, tmp: work), again != refPCM {
                print("  (Core Audio decodes the untouched ORIGINAL differently each run here (\(refPCM.suffix(12)) vs \(again.suffix(12))): decoder is not deterministic in this environment, so this comparison is skipped; ffmpeg comparison still applies)")
            } else {
            check(got == refPCM, "Core Audio decoded audio differs (original: \(refPCM), tagged: \(got ?? "decode failed"))")
            }
        }
        if let refMD5 { check(ffmpegMD5(copy.path) == refMD5, "ffmpeg decoded audio differs / decode errors") }
        if let refProbe, let p = ffprobeInfo(copy.path) {
            check(p.tags == refProbe.tags, "ffprobe tags differ: \(Set(p.tags.map { "\($0)=\($1)" }).symmetricDifference(Set(refProbe.tags.map { "\($0)=\($1)" })))")
            check(p.duration == refProbe.duration, "duration differs \(refProbe.duration) → \(p.duration)")
            check(p.errors.isEmpty, "ffprobe errors: \(p.errors)")
        } else if refProbe != nil { problems.append("ffprobe can't read the tagged copy") }
        if let refMeta { check((try? nonSeratoMetadata(copy)) == refMeta, "non-Serato tags/artwork changed") }
        check(run(["afinfo", copy.path]).status == 0, "afinfo can't read tagged copy")

        let after = try? fm.attributesOfItem(atPath: orig)
        check((after?[.modificationDate] as? Date) == origMod, "ORIGINAL was modified!")

        let grow = sizes.map { $0 - size0 }
        if problems.isEmpty {
            print("  ✓ all checks passed (size +\(grow[0]) B after first write, then in place: \(grow == [grow[0], grow[0], grow[0]] ? "yes" : "no, \(grow)"))")
        } else {
            for p in problems { print("  ✗ \(p)") }
            failedFiles.append(name)
        }
        if problems.isEmpty { try? fm.removeItem(at: dir) } else { print("  (kept failing copy for inspection: \(copy.path))") }
    }
    print(failedFiles.isEmpty ? "\nREAL FILES: ALL \(originals.count) PASSED" : "\nREAL FILES: \(failedFiles.count) FAILED: \(failedFiles)")
    return failedFiles.isEmpty ? 0 : 1
}

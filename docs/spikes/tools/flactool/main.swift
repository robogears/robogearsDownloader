// flactool: RobogearsCore's FLAC reader and native writer as a command, for
// the spike in docs/spikes/audio-and-tagging.md. It compiles the package's
// own source files, so what it prints and writes is exactly what the app does.
//
// Build (from the repository root):
//   P=macos/Packages/RobogearsCore/Sources/RobogearsCore
//   swiftc -O -module-name flactool $P/RobogearsCore.swift $P/Download/FLACMetadata.swift \
//     $P/Download/FLACMetadataReader.swift $P/Download/FMP4FLACExtractor.swift \
//     $P/Download/FLACWriter.swift docs/spikes/tools/flactool/main.swift -o /tmp/flactool
//
// Use:
//   flactool dump <file.flac>
//   flactool write <download: native .flac or joined DASH .mp4> <cover.jpg> <out.flac> [key=value …]
// Tag keys for `write` are the FFmpeg -metadata keys the Electron app used:
// title artist album album_artist track disc date copyright isrc.
import Foundation

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func dump(_ path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    let layout = try FLACMetadataReader.read(data)
    print("file: \((path as NSString).lastPathComponent)  bytes: \(data.count)  leading tag: \(layout.leadingTagSize)")
    for (index, block) in layout.blocks.enumerated() {
        let name = block.type.map { "\($0)" } ?? "type \(block.typeCode)"
        let last = index == layout.blocks.count - 1 ? "  (last)" : ""
        print("block \(index): \(name), \(block.body.count) bytes\(last)")
        switch block.type {
        case .streamInfo:
            let s = try FLACStreamInfo(bytes: block.body)
            print("  \(s.sampleRate) Hz, \(s.channelCount) ch, \(s.bitsPerSample) bit, \(s.totalSamples) samples, blocks \(s.minimumBlockSize)-\(s.maximumBlockSize), frames \(s.minimumFrameSize)-\(s.maximumFrameSize) bytes, md5 \(hex(s.md5))")
        case .vorbisComment:
            let c = try FLACVorbisComment(bytes: block.body)
            print("  vendor: \(c.vendor)")
            for field in c.fields { print("  \(field.name)=\(field.value)") }
        case .picture:
            let p = try FLACPicture(bytes: block.body)
            print("  type \(p.pictureType), \(p.mimeType), \"\(p.description)\", \(p.width)x\(p.height), depth \(p.colorDepth), colors \(p.colorCount), \(p.data.count) bytes of image")
        case .padding:
            print("  all zero: \(block.body.allSatisfy { $0 == 0 })")
        default:
            break
        }
    }
    print("audio frames: start at byte \(layout.audioOffset), \(data.count - layout.audioOffset) bytes")
}

func write(_ args: ArraySlice<String>) throws {
    let parts = Array(args)
    guard parts.count >= 3 else { throw CocoaError(.fileReadInvalidFileName) }
    let start = ContinuousClock.now
    let source = try Data(contentsOf: URL(fileURLWithPath: parts[0]), options: .alwaysMapped)
    let cover = try Data(contentsOf: URL(fileURLWithPath: parts[1]))
    var tags = FLACTags()
    for pair in parts.dropFirst(3) {
        guard let eq = pair.firstIndex(of: "=") else { continue }
        let key = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
        switch key {
        case "title": tags.title = value
        case "artist": tags.artist = value
        case "album": tags.album = value
        case "album_artist": tags.albumArtist = value
        case "track": tags.trackNumber = Int(value)
        case "disc": tags.discNumber = Int(value)
        case "date": tags.year = value
        case "copyright": tags.copyright = value
        case "isrc": tags.isrc = value
        default: print("ignored unknown key \(key)")
        }
    }
    let audio = try FLACAudio(downloaded: source)
    try FLACWriter.write(audio, tags: tags, coverJPEG: cover, to: URL(fileURLWithPath: parts[2]))
    let elapsed = ContinuousClock.now - start
    let counted = audio.countedSampleCount.map(String.init) ?? "n/a (native FLAC)"
    print("wrote \(parts[2]): declared samples \(audio.declaredSampleCount), counted \(counted), written \(audio.streamInfo.totalSamples), \(audio.frameRanges.count) frame ranges, \(audio.frameByteCount) frame bytes, \(elapsed)")
}

let arguments = CommandLine.arguments
do {
    switch arguments.count > 1 ? arguments[1] : "" {
    case "dump": try arguments.dropFirst(2).forEach(dump)
    case "write": try write(arguments.dropFirst(2))
    default: print("usage: flactool dump <file.flac>… | flactool write <download> <cover.jpg> <out.flac> [key=value …]")
    }
} catch {
    print("error: \(error)")
    exit(1)
}

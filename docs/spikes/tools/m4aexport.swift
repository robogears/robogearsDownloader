// m4aexport: can AVFoundation do the Electron app's .m4a step (copy the AAC
// audio untouched, add the iTunes tags and cover) without FFmpeg?
// Spike tool for docs/spikes/audio-and-tagging.md.
//
//   swiftc -O docs/spikes/tools/m4aexport.swift -o /tmp/m4aexport
//   /tmp/m4aexport <source .m4a or joined DASH AAC .mp4> <cover.jpg> <out.m4a>
//
// Uses passthrough export (no re-encoding) and the same tag values the
// fixture script gives FFmpeg. ISRC is left out because FFmpeg's .m4a had none.
import AVFoundation
import Foundation

func item(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, dataType: String? = nil) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = id
    item.value = value
    if let dataType { item.dataType = dataType }
    return item
}

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: m4aexport <source> <cover.jpg> <out.m4a>"); exit(2) }
let source = URL(fileURLWithPath: args[1])
let cover = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let output = URL(fileURLWithPath: args[3])

let asset = AVURLAsset(url: source)
guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
    print("no passthrough session for \(source.lastPathComponent)"); exit(1)
}
session.metadata = [
    item(.iTunesMetadataSongName, "Blue Lantern – Café 東京" as NSString),
    item(.iTunesMetadataArtist, "Placeholder Artist, Second Example" as NSString),
    item(.iTunesMetadataAlbum, "Paper Harbour" as NSString),
    item(.iTunesMetadataAlbumArtist, "Placeholder Artist" as NSString),
    item(.iTunesMetadataTrackNumber, Data([0, 0, 0, 7, 0, 0, 0, 0]) as NSData),
    item(.iTunesMetadataDiscNumber, Data([0, 0, 0, 1, 0, 0]) as NSData),
    item(.iTunesMetadataReleaseDate, "2011" as NSString),
    item(.iTunesMetadataCopyright, "℗ 2011 Example Records" as NSString),
    item(.iTunesMetadataCoverArt, cover as NSData, dataType: kCMMetadataBaseDataType_JPEG as String),
]
let start = ContinuousClock.now
do {
    try await session.export(to: output, as: .m4a)
    print("exported \(output.lastPathComponent) in \(ContinuousClock.now - start)")
} catch {
    print("export FAILED: \(error)")
    exit(1)
}

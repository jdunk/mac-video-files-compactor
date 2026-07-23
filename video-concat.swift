import AVFoundation
import Foundation

enum ConcatError: LocalizedError {
    case usage
    case fileNotFound(String)
    case unsupportedExtension(String)
    case invalidDuration(String)
    case cannotCreateExportSession

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: video-concat FILE1 FILE2 [FILE3 ...]"
        case .fileNotFound(let path):
            return "Not a file: \(path)"
        case .unsupportedExtension(let ext):
            return "The first file must be .mov or .mp4 (got .\(ext))."
        case .invalidDuration(let path):
            return "Could not determine video duration: \(path)"
        case .cannotCreateExportSession:
            return "The files cannot be concatenated with AVFoundation passthrough."
        }
    }
}

func concatOutputURL(for firstInput: URL) throws -> (URL, AVFileType) {
    let ext = firstInput.pathExtension.lowercased()
    let fileType: AVFileType

    switch ext {
    case "mov":
        fileType = .mov
    case "mp4":
        fileType = .mp4
    default:
        throw ConcatError.unsupportedExtension(ext)
    }

    let stem = firstInput.deletingPathExtension().lastPathComponent
    let output = firstInput.deletingLastPathComponent()
        .appendingPathComponent("\(stem)-concatenated")
        .appendingPathExtension(ext)
    return (output, fileType)
}

func concatenateVideos() async throws {
    guard CommandLine.arguments.count >= 3 else {
        throw ConcatError.usage
    }

    let inputURLs = CommandLine.arguments.dropFirst().map {
        URL(fileURLWithPath: $0).standardizedFileURL
    }

    for url in inputURLs {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw ConcatError.fileNotFound(url.path)
        }
    }

    let composition = AVMutableComposition()
    guard let compositionVideo = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
        throw ConcatError.cannotCreateExportSession
    }

    var compositionAudio: AVMutableCompositionTrack?
    var destination = CMTime.zero

    for url in inputURLs {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard duration.isValid, duration.isNumeric, duration.seconds > 0 else {
            throw ConcatError.invalidDuration(url.path)
        }

        let range = CMTimeRange(start: .zero, duration: duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else {
            throw ConcatError.cannotCreateExportSession
        }

        if destination == .zero {
            compositionVideo.preferredTransform = try await sourceVideo.load(
                .preferredTransform
            )
        }
        try compositionVideo.insertTimeRange(
            range,
            of: sourceVideo,
            at: destination
        )

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudio = audioTracks.first {
            if compositionAudio == nil {
                compositionAudio = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                if destination > .zero {
                    compositionAudio?.insertEmptyTimeRange(
                        CMTimeRange(start: .zero, duration: destination)
                    )
                }
            }
            try compositionAudio?.insertTimeRange(
                range,
                of: sourceAudio,
                at: destination
            )
        } else {
            compositionAudio?.insertEmptyTimeRange(
                CMTimeRange(start: destination, duration: duration)
            )
        }

        destination = destination + duration
    }

    let (outputURL, fileType) = try concatOutputURL(for: inputURLs[0])
    if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
    }

    guard let exporter = AVAssetExportSession(
        asset: composition,
        presetName: AVAssetExportPresetPassthrough
    ) else {
        throw ConcatError.cannotCreateExportSession
    }

    exporter.shouldOptimizeForNetworkUse = true
    try await exporter.export(to: outputURL, as: fileType)
    print(outputURL.path)
}

Task {
    do {
        try await concatenateVideos()
        exit(0)
    } catch {
        fputs("video-concat: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

dispatchMain()

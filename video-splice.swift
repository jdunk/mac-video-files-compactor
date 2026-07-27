import AVFoundation
import Foundation

enum SpliceError: LocalizedError {
    case usage
    case unsupportedExtension(String)
    case invalidTime(String)
    case invalidRange(String)
    case rangeOutsideVideo(String)
    case cannotCreateExportSession

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: video-splice FILENAME START,END [START,END ...] [FINAL_START]"
        case .unsupportedExtension(let ext):
            return "Only .mov and .mp4 output is supported (got .\(ext))."
        case .invalidTime(let value):
            return "Invalid time: \(value)"
        case .invalidRange(let value):
            return "Invalid cut range: \(value)"
        case .rangeOutsideVideo(let value):
            return "Cut range is outside the video duration: \(value)"
        case .cannotCreateExportSession:
            return "The file cannot be exported with AVFoundation passthrough."
        }
    }
}

struct Cut {
    let start: Double
    let end: Double?
    let source: String
}

func parseTime(_ value: String) throws -> Double {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else {
        throw SpliceError.invalidTime(value)
    }

    var seconds = 0.0
    for part in parts {
        guard let number = Double(part), number.isFinite, number >= 0 else {
            throw SpliceError.invalidTime(value)
        }
        seconds = seconds * 60 + number
    }
    return seconds
}

func parseCut(_ value: String) throws -> Cut {
    let bounds = value.split(separator: ",", omittingEmptySubsequences: false)
    guard bounds.count == 1 || bounds.count == 2 else {
        throw SpliceError.invalidRange(value)
    }

    let start = try parseTime(String(bounds[0]))
    var end: Double?

    if bounds.count == 2 && !bounds[1].isEmpty {
        end = try parseTime(String(bounds[1]))
        guard start < end! else {
            throw SpliceError.invalidRange(value)
        }
    }

    return Cut(start: start, end: end, source: value)
}

func outputURL(for inputURL: URL) throws -> (URL, AVFileType) {
    let ext = inputURL.pathExtension.lowercased()
    let fileType: AVFileType

    switch ext {
    case "mov":
        fileType = .mov
    case "mp4":
        fileType = .mp4
    default:
        throw SpliceError.unsupportedExtension(ext)
    }

    let stem = inputURL.deletingPathExtension().lastPathComponent
    let output = inputURL.deletingLastPathComponent()
        .appendingPathComponent("\(stem)-spliced")
        .appendingPathExtension(ext)
    return (output, fileType)
}

func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else {
        throw CocoaError(.fileReadUnknown)
    }
    return size.int64Value
}

func printSizeSummary(original: Int64, new: Int64) {
    let saved = original - new
    let percentage = original > 0
        ? Double(saved) * 100 / Double(original)
        : 0

    print(String(format: "Original size:     %.2f MB", Double(original) / 1_000_000))
    print(String(format: "New size:          %.2f MB", Double(new) / 1_000_000))
    print(String(
        format: "Disk space saved:  %.2f MB (%.1f%%)",
        Double(saved) / 1_000_000,
        percentage
    ))
}

func spliceVideo() async throws {
            guard CommandLine.arguments.count >= 3 else {
                throw SpliceError.usage
            }

            let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: inputURL.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let originalSize = try fileSize(at: inputURL)

            let parsedCuts = try CommandLine.arguments.dropFirst(2).map(parseCut)
            let asset = AVURLAsset(url: inputURL)
            let duration = try await asset.load(.duration)
            let durationSeconds = duration.seconds

            guard durationSeconds.isFinite && durationSeconds > 0 else {
                throw SpliceError.rangeOutsideVideo("unknown duration")
            }

            for (index, cut) in parsedCuts.enumerated() {
                if cut.end == nil && index != parsedCuts.count - 1 {
                    throw SpliceError.invalidRange(
                        "\(cut.source) omits CUT_END but is not the final cut"
                    )
                }
            }

            let cuts = parsedCuts.map {
                Cut(start: $0.start, end: $0.end ?? durationSeconds, source: $0.source)
            }

            var previousEnd = 0.0
            for cut in cuts {
                let cutEnd = cut.end!
                guard cut.start >= previousEnd else {
                    throw SpliceError.invalidRange(
                        "\(cut.source) overlaps or is out of order"
                    )
                }
                guard cut.start < cutEnd, cutEnd <= durationSeconds else {
                    throw SpliceError.rangeOutsideVideo(cut.source)
                }
                previousEnd = cutEnd
            }

            let composition = AVMutableComposition()
            let timeScale: CMTimeScale = 60_000
            var sourceStart = 0.0
            var destination = CMTime.zero

            for cut in cuts {
                let cutEnd = cut.end!
                if cut.start > sourceStart {
                    let start = CMTime(seconds: sourceStart, preferredTimescale: timeScale)
                    let end = CMTime(seconds: cut.start, preferredTimescale: timeScale)
                    let range = CMTimeRange(start: start, end: end)
                    try await composition.insertTimeRange(range, of: asset, at: destination)
                    destination = destination + range.duration
                }
                sourceStart = cutEnd
            }

            if sourceStart < durationSeconds {
                let start = CMTime(seconds: sourceStart, preferredTimescale: timeScale)
                let range = CMTimeRange(start: start, end: duration)
                try await composition.insertTimeRange(range, of: asset, at: destination)
            }

            let (destinationURL, fileType) = try outputURL(for: inputURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            guard let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw SpliceError.cannotCreateExportSession
            }

            exporter.shouldOptimizeForNetworkUse = true
            try await exporter.export(to: destinationURL, as: fileType)
            print(destinationURL.path)
            let newSize = try fileSize(at: destinationURL)
            printSizeSummary(original: originalSize, new: newSize)
}

Task {
    do {
        try await spliceVideo()
        exit(0)
        } catch {
            fputs("video-splice: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
}

dispatchMain()

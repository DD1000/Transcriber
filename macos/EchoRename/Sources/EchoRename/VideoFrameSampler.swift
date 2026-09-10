@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SampledVideoFrames: Sendable {
    let directory: URL
    let images: [URL]
}

enum VideoFrameSamplingError: LocalizedError {
    case noReadableVideo
    case noReadableFrames
    case couldNotSaveFrame
    case samplingTimedOut

    var errorDescription: String? {
        switch self {
        case .noReadableVideo:
            "macOS could not read a video track from this file."
        case .noReadableFrames:
            "macOS could not extract any pictures from this video."
        case .couldNotSaveFrame:
            "ClipName could not save a temporary picture for visual analysis."
        case .samplingTimedOut:
            "Preparing pictures from this video took too long. Try another video or retry this one."
        }
    }
}

enum VideoFrameSampler {
    /// The caller owns the returned directory and must remove it after analysis.
    static func sample(videoAt videoURL: URL) async throws -> SampledVideoFrames {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipname-frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: directory) }
        }
        let result = try await withThrowingTaskGroup(of: SampledVideoFrames.self) { group in
            group.addTask {
                let session = FrameSamplingSession(videoURL: videoURL)
                defer { session.cancel() }
                return try await withTaskCancellationHandler {
                    try await sampleFrames(using: session, directory: directory)
                } onCancel: {
                    session.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw VideoFrameSamplingError.samplingTimedOut
            }
            defer { group.cancelAll() }
            guard let samples = try await group.next() else {
                throw VideoFrameSamplingError.noReadableFrames
            }
            return samples
        }
        try Task.checkCancellation()
        completed = true
        return result
    }

    private static func sampleFrames(using session: FrameSamplingSession, directory: URL) async throws -> SampledVideoFrames {
        try Task.checkCancellation()
        let asset = session.asset
        let duration: Double
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw VideoFrameSamplingError.noReadableVideo }
            duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw VideoFrameSamplingError.noReadableVideo
            }
        } catch {
            try Task.checkCancellation()
            throw VideoFrameSamplingError.noReadableVideo
        }

        let generator = session.generator

        // Decode and save one small picture at a time, avoiding a buffer of full-size frames.
        let fractions: [Double] = duration < 1 ? [0.5] : [0.1, 0.35, 0.65, 0.9]
        var images: [URL] = []
        for (index, fraction) in fractions.enumerated() {
            try Task.checkCancellation()
            do {
                let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
                let result = try await generator.image(at: time)
                try Task.checkCancellation()
                let output = directory.appendingPathComponent("frame-\(index + 1).jpg")
                try autoreleasepool { try saveJPEG(result.image, to: output) }
                images.append(output)
            } catch let error as VideoFrameSamplingError {
                throw error
            } catch {
                try Task.checkCancellation()
                // A damaged section should not prevent the other samples from being used.
                continue
            }
        }

        guard !images.isEmpty else { throw VideoFrameSamplingError.noReadableFrames }
        try Task.checkCancellation()
        return SampledVideoFrames(directory: directory, images: images)
    }

    private static func saveJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw VideoFrameSamplingError.couldNotSaveFrame
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw VideoFrameSamplingError.couldNotSaveFrame
        }
    }
}

/// AVFoundation's cancellation methods may be invoked while asynchronous loading/generation runs.
/// Configuration is finished before sharing the session; concurrent access only requests cancellation.
private final class FrameSamplingSession: @unchecked Sendable {
    let asset: AVURLAsset
    let generator: AVAssetImageGenerator

    init(videoURL: URL) {
        asset = AVURLAsset(url: videoURL)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
    }

    func cancel() {
        asset.cancelLoading()
        generator.cancelAllCGImageGeneration()
    }
}

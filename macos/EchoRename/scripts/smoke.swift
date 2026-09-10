@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Compile alongside VideoFrameSampler.swift, SpeechNamingPolicy.swift and TitleGenerator.swift.
/// Generates synthetic media only; it never reads or changes the user's video collection.
@main
struct ClipNameSmoke {
    struct CheckFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailed(message: message) }
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipname-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        try checkSpeechAndTitles()
        print("PASS: speech fallback policy and safe English/Spanish filenames")

        let landscape = directory.appendingPathComponent("silent-colors.mp4")
        try await makeVideo(at: landscape, rotated: false)
        let landscapeAsset = AVURLAsset(url: landscape)
        let audioTracks = try await landscapeAsset.loadTracks(withMediaType: .audio)
        try require(audioTracks.isEmpty, "The synthetic video should have no audio track.")
        try await checkFrames(at: landscape, portrait: false)
        print("PASS: silent video yields four readable, downscaled JPEG frames")

        let portrait = directory.appendingPathComponent("rotated-colors.mp4")
        try await makeVideo(at: portrait, rotated: true)
        try await checkFrames(at: portrait, portrait: true)
        print("PASS: sampled frames respect the video's display rotation")

        let invalid = directory.appendingPathComponent("invalid.mp4")
        try Data("This is not a video.".utf8).write(to: invalid)
        try await expectUnreadableVideo(at: invalid)
        let audioOnly = directory.appendingPathComponent("audio-only.wav")
        try makeAudio(at: audioOnly)
        try await expectUnreadableVideo(at: audioOnly)
        print("PASS: invalid and audio-only files produce a readable-video error")

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VideoFrameSampler.sample(videoAt: landscape)
        }
        do {
            let unexpected = try await cancelled.value
            try? FileManager.default.removeItem(at: unexpected.directory)
            throw CheckFailed(message: "A cancelled frame-sampling task unexpectedly succeeded.")
        } catch is CancellationError {
            print("PASS: frame sampling honors cancellation")
        }
        print("All ClipName native smoke checks passed.")
    }

    private static func checkSpeechAndTitles() throws {
        for text in [
            "", "[Music]", "(música)", "♪♫", "music music music music",
            "um uh oh hmm", "Thank you for watching.", "Gracias por ver el video.",
            "Subtitles by Amara.org",
        ] {
            try require(!SpeechNamingPolicy.hasUsefulSpeech(text), "Expected visual fallback for: \(text)")
        }
        for text in [
            "We are hiking beside the river this morning.",
            "Estamos caminando por la playa al atardecer.",
            "[Music] The children are building a sandcastle beside the ocean.",
        ] {
            try require(SpeechNamingPolicy.hasUsefulSpeech(text), "Rejected useful speech: \(text)")
        }
        let english = TitleGenerator.filename(
            from: "Sunset over ocean", preservingExtension: "MOV", fallback: "untitled"
        )
        try require(english == "sunset-over-ocean.mov", "Unexpected scenery title: \(english)")
        let spanish = TitleGenerator.filename(
            from: "Estamos caminando por la playa al atardecer.", preservingExtension: "mp4", fallback: "original"
        )
        try require(spanish.contains("playa") && spanish.hasSuffix(".mp4"), "Spanish title lost its subject or extension.")
        let spanishFillers = TitleGenerator.filename(
            from: "Preparando parapente para mañana en la montaña.",
            preservingExtension: "MP4", fallback: "original"
        )
        try require(spanishFillers == "preparando-parapente-mañana-montaña.mp4", "Spanish fillers must be removed as whole words, preserving accents and subjects.")
        let unsafe = TitleGenerator.filename(
            from: "Mountain / river: evening\\walk", preservingExtension: "mp4", fallback: "original"
        )
        try require(!unsafe.contains("/") && !unsafe.contains(":") && !unsafe.contains("\\"), "A title contains path separators.")
        let empty = TitleGenerator.filename(from: "", preservingExtension: "MOV", fallback: "original-video")
        try require(empty == "original-video.mov", "Empty descriptions should preserve the fallback filename.")
    }

    private static func checkFrames(at video: URL, portrait: Bool) async throws {
        let sampled = try await VideoFrameSampler.sample(videoAt: video)
        defer { try? FileManager.default.removeItem(at: sampled.directory) }
        try require(sampled.images.count == 4, "Expected four frames, received \(sampled.images.count).")
        try require(Set(sampled.images).count == 4, "Sampled frame paths must be distinct.")
        var dominantColors = Set<Int>()
        for url in sampled.images {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CheckFailed(message: "A sampled JPEG cannot be decoded: \(url.lastPathComponent)")
            }
            try require(image.width <= 512 && image.height <= 512, "A sampled frame exceeds the 512px bound.")
            try require(max(image.width, image.height) == 512, "Expected the larger synthetic video to be downscaled to 512px.")
            try require(portrait ? image.height > image.width : image.width > image.height, "The display rotation was not applied.")
            dominantColors.insert(try dominantColor(in: image))
        }
        try require(dominantColors.count >= 2, "Frames should sample different colored sections of the video.")
    }

    private static func dominantColor(in image: CGImage) throws -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { throw CheckFailed(message: "Could not inspect the sampled image color.") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (0..<3).max { pixel[$0] < pixel[$1] }!
    }

    private static func expectUnreadableVideo(at url: URL) async throws {
        do {
            let unexpected = try await VideoFrameSampler.sample(videoAt: url)
            try? FileManager.default.removeItem(at: unexpected.directory)
            throw CheckFailed(message: "Frame sampling unexpectedly accepted \(url.lastPathComponent).")
        } catch VideoFrameSamplingError.noReadableVideo {
            // Expected typed error, rather than an empty visual-analysis request.
        }
    }

    private static func makeAudio(at url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600),
              let samples = buffer.floatChannelData?[0] else {
            throw CheckFailed(message: "Could not create the synthetic audio fixture.")
        }
        buffer.frameLength = 1_600
        samples.initialize(repeating: 0, count: 1_600)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func makeVideo(at url: URL, rotated: Bool) async throws {
        let width = 640
        let height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        if rotated {
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        try require(writer.canAdd(input), "macOS cannot encode the synthetic video fixture.")
        writer.add(input)
        try require(writer.startWriting(), "Video fixture encoding did not start: \(writer.error?.localizedDescription ?? "unknown error")")
        writer.startSession(atSourceTime: .zero)
        do {
            for index in 0..<40 {
                let deadline = Date().addingTimeInterval(20)
                while !input.isReadyForMoreMediaData {
                    try require(writer.status == .writing && Date() < deadline, "Video fixture encoding stalled.")
                    try await Task.sleep(for: .milliseconds(2))
                }
                let buffer = try colorBuffer(width: width, height: height, color: min(index / 13, 2))
                try require(
                    adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)),
                    "Could not append a synthetic video frame: \(writer.error?.localizedDescription ?? "unknown error")"
                )
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: 4, preferredTimescale: 10))
            await writer.finishWriting()
            try require(writer.status == .completed, "Video fixture encoding failed: \(writer.error?.localizedDescription ?? "unknown error")")
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    private static func colorBuffer(width: Int, height: Int, color: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &result)
        guard status == kCVReturnSuccess, let buffer = result else {
            throw CheckFailed(message: "Could not allocate a synthetic video frame.")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw CheckFailed(message: "Could not access a synthetic video frame.")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * stride + column * 4
                bytes[offset] = color == 2 ? 240 : 10
                bytes[offset + 1] = color == 1 ? 240 : 10
                bytes[offset + 2] = color == 0 ? 240 : 10
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }
}

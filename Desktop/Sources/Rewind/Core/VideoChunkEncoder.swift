import AppKit
import CoreGraphics
import Foundation
import Sentry

/// Encodes screenshot frames into H.265 video chunks using ffmpeg for efficient storage.
/// Uses fragmented MP4 format so frames can be read while the file is still being written.
actor VideoChunkEncoder {
    static let shared = VideoChunkEncoder()

    // Track if we've reported ffmpeg source this session (once per app launch)
    private static var hasReportedFFmpegSource = false

    // MARK: - Configuration

    private let chunkDuration: TimeInterval = 60.0 // 60-second chunks
    private let frameRate: Double = 1.0 // 1 FPS (matching current capture rate)
    private let maxResolution: CGFloat = 3000 // Maximum dimension

    // MARK: - State

    private var frameBuffer: [(image: CGImage, timestamp: Date)] = []
    private var currentChunkStartTime: Date?
    private var currentChunkPath: String?
    private var frameOffsetInChunk: Int = 0

    // FFmpeg process state
    private var ffmpegProcess: Process?
    private var ffmpegStdin: FileHandle?
    private var currentOutputSize: CGSize?

    private var videosDirectory: URL?
    private var isInitialized = false

    // MARK: - Types

    struct EncodedFrame {
        let videoChunkPath: String // Relative path to .mp4
        let frameOffset: Int // Frame index within chunk
        let timestamp: Date
    }

    struct ChunkFlushResult {
        let videoChunkPath: String
        let frames: [EncodedFrame]
    }

    // MARK: - Initialization

    private init() {}

    /// Initialize the encoder with the videos directory
    func initialize(videosDirectory: URL) async throws {
        guard !isInitialized else { return }

        self.videosDirectory = videosDirectory
        isInitialized = true
        log("VideoChunkEncoder: Initialized at \(videosDirectory.path)")
    }

    // MARK: - Frame Processing

    /// Add a frame to the buffer. Returns encoded info if this frame completed a chunk.
    func addFrame(image: CGImage, timestamp: Date) async throws -> EncodedFrame? {
        guard isInitialized, let videosDir = videosDirectory else {
            throw RewindError.storageError("VideoChunkEncoder not initialized")
        }

        // Start new chunk if needed
        if currentChunkStartTime == nil {
            currentChunkStartTime = timestamp
            currentChunkPath = generateChunkPath(for: timestamp)
            frameOffsetInChunk = 0

            // Start ffmpeg process for this chunk
            try await startFFmpegProcess(
                for: currentChunkPath!,
                videosDir: videosDir,
                imageSize: CGSize(width: image.width, height: image.height)
            )
        }

        // Add frame to buffer
        frameBuffer.append((image: image, timestamp: timestamp))

        let frameInfo = EncodedFrame(
            videoChunkPath: currentChunkPath!,
            frameOffset: frameOffsetInChunk,
            timestamp: timestamp
        )

        frameOffsetInChunk += 1

        // Write frame to ffmpeg
        try await writeFrame(image: image)

        // Check if chunk duration exceeded
        if let startTime = currentChunkStartTime,
           timestamp.timeIntervalSince(startTime) >= chunkDuration
        {
            // Finalize current chunk
            try await finalizeCurrentChunk()
            return frameInfo
        }

        return frameInfo
    }

    /// Force flush current buffer (app termination, etc.)
    func flushCurrentChunk() async throws -> ChunkFlushResult? {
        guard currentChunkPath != nil, !frameBuffer.isEmpty else {
            return nil
        }

        let chunkPath = currentChunkPath!
        let frames = frameBuffer.enumerated().map { index, item in
            EncodedFrame(
                videoChunkPath: chunkPath,
                frameOffset: index,
                timestamp: item.timestamp
            )
        }

        try await finalizeCurrentChunk()

        return ChunkFlushResult(videoChunkPath: chunkPath, frames: frames)
    }

    // MARK: - FFmpeg Process Management

    private func startFFmpegProcess(for relativePath: String, videosDir: URL, imageSize: CGSize) async throws {
        // Create day subdirectory if needed
        let components = relativePath.components(separatedBy: "/")
        if components.count > 1 {
            let dayDir = videosDir.appendingPathComponent(components[0], isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        }

        let fullPath = videosDir.appendingPathComponent(relativePath)

        // Calculate output size (maintain aspect ratio, max 3000)
        let outputSize = calculateOutputSize(for: imageSize)
        currentOutputSize = outputSize

        // Find ffmpeg path
        let ffmpegPath = findFFmpegPath()

        // Build ffmpeg command
        // Uses fragmented MP4 so the file can be read while still being written
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-f", "image2pipe",
            "-vcodec", "png",
            "-r", String(frameRate),
            "-i", "-",
            "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", // Ensure even dimensions
            "-vcodec", "libx265",
            "-tag:v", "hvc1",
            "-preset", "ultrafast",
            "-crf", "0",  // Lossless quality
            // Fragmented MP4 - allows reading while writing
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-pix_fmt", "yuv420p",
            "-y", // Overwrite output
            fullPath.path
        ]

        // Set up pipes
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        ffmpegProcess = process
        ffmpegStdin = stdinPipe.fileHandleForWriting

        log("VideoChunkEncoder: Started ffmpeg for chunk at \(relativePath)")

        // Log frame dimensions to Sentry for debugging user quality issues
        let breadcrumb = Breadcrumb(level: .info, category: "video_encoder")
        breadcrumb.message = "Started video chunk encoding"
        breadcrumb.data = [
            "chunk_path": relativePath,
            "input_width": Int(imageSize.width),
            "input_height": Int(imageSize.height),
            "output_width": Int(outputSize.width),
            "output_height": Int(outputSize.height),
            "crf": 0,
            "max_resolution": Int(maxResolution)
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    private func writeFrame(image: CGImage) async throws {
        guard let stdin = ffmpegStdin,
              let outputSize = currentOutputSize
        else {
            throw RewindError.storageError("FFmpeg not ready")
        }

        // Scale image if needed and convert to PNG data
        let scaledImage = scaleImage(image, to: outputSize)
        guard let pngData = createPNGData(from: scaledImage) else {
            throw RewindError.storageError("Failed to create PNG data")
        }

        // Write to ffmpeg stdin
        do {
            try stdin.write(contentsOf: pngData)
        } catch {
            throw RewindError.storageError("Failed to write frame to ffmpeg: \(error.localizedDescription)")
        }
    }

    private func finalizeCurrentChunk() async throws {
        // Close stdin to signal end of input to ffmpeg
        if let stdin = ffmpegStdin {
            try? stdin.close()
            ffmpegStdin = nil
        }

        // Wait for ffmpeg to finish
        if let process = ffmpegProcess {
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                logError("VideoChunkEncoder: FFmpeg exited with status \(process.terminationStatus)")
            } else {
                log("VideoChunkEncoder: Finalized chunk with \(frameBuffer.count) frames")
            }

            ffmpegProcess = nil
        }

        // Reset state
        frameBuffer.removeAll()
        currentChunkStartTime = nil
        currentChunkPath = nil
        frameOffsetInChunk = 0
        currentOutputSize = nil
    }

    // MARK: - Helpers

    private func generateChunkPath(for timestamp: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayString = dateFormatter.string(from: timestamp)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"
        let timeString = timeFormatter.string(from: timestamp)

        return "\(dayString)/chunk_\(timeString).mp4"
    }

    private func calculateOutputSize(for size: CGSize) -> CGSize {
        let maxDimension = max(size.width, size.height)

        if maxDimension <= maxResolution {
            // Round to even numbers (required by video codecs)
            return CGSize(
                width: CGFloat(Int(size.width) / 2 * 2),
                height: CGFloat(Int(size.height) / 2 * 2)
            )
        }

        let scale = maxResolution / maxDimension
        let newWidth = Int(size.width * scale) / 2 * 2
        let newHeight = Int(size.height * scale) / 2 * 2

        return CGSize(width: CGFloat(newWidth), height: CGFloat(newHeight))
    }

    private func scaleImage(_ image: CGImage, to targetSize: CGSize) -> CGImage {
        let currentSize = CGSize(width: image.width, height: image.height)

        // If already the right size, return as-is
        if currentSize.width == targetSize.width && currentSize.height == targetSize.height {
            return image
        }

        // Create a context at the target size
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: targetSize))

        return context.makeImage() ?? image
    }

    private func createPNGData(from image: CGImage) -> Data? {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        return bitmapRep.representation(using: .png, properties: [:])
    }

    private func findFFmpegPath() -> String {
        // Common locations for ffmpeg (bundled first for users without Homebrew)
        // Use Bundle.resourceBundle for SPM resources (they're in a nested bundle, not main bundle)
        let bundledPath = Bundle.resourceBundle.path(forResource: "ffmpeg", ofType: nil)
        let possiblePaths: [(path: String, source: String)] = [
            (bundledPath ?? "", "bundled"),
            ("/opt/homebrew/bin/ffmpeg", "homebrew"),
            ("/usr/local/bin/ffmpeg", "usr_local"),
            ("/usr/bin/ffmpeg", "system"),
        ].filter { !$0.path.isEmpty }

        for (path, source) in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                reportFFmpegSource(source: source, path: path)
                return path
            }
        }

        // Fall back to PATH lookup
        reportFFmpegSource(source: "path_fallback", path: "ffmpeg")
        return "ffmpeg"
    }

    private func reportFFmpegSource(source: String, path: String) {
        // Only report once per app launch
        guard !Self.hasReportedFFmpegSource else { return }
        Self.hasReportedFFmpegSource = true

        Task { @MainActor in
            PostHogManager.shared.ffmpegResolved(source: source, path: path)
        }
    }

    // MARK: - Cleanup

    /// Cancel any in-progress encoding and clean up
    func cancel() async {
        // Close stdin first
        if let stdin = ffmpegStdin {
            try? stdin.close()
            ffmpegStdin = nil
        }

        // Terminate ffmpeg process
        if let process = ffmpegProcess {
            process.terminate()
            ffmpegProcess = nil
        }

        frameBuffer.removeAll()
        currentChunkStartTime = nil
        currentChunkPath = nil
        frameOffsetInChunk = 0
        currentOutputSize = nil
    }
}

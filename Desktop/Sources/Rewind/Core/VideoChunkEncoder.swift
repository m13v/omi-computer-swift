import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

/// Encodes screenshot frames into H.265 video chunks for efficient storage
actor VideoChunkEncoder {
    static let shared = VideoChunkEncoder()

    // MARK: - Configuration

    private let chunkDuration: TimeInterval = 60.0 // 60-second chunks
    private let frameRate: Double = 1.0 // 1 FPS (matching current capture rate)
    private let maxResolution: CGFloat = 1024 // Maximum dimension

    // MARK: - State

    private var frameBuffer: [(image: CGImage, timestamp: Date)] = []
    private var currentChunkStartTime: Date?
    private var currentChunkPath: String?
    private var frameOffsetInChunk: Int = 0

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

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

            // Create the asset writer for this chunk
            try await setupAssetWriter(
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

        // Write frame to video
        try await writeFrame(image: image, frameIndex: frameOffsetInChunk - 1)

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

    // MARK: - Asset Writer Setup

    private func setupAssetWriter(for relativePath: String, videosDir: URL, imageSize: CGSize) async throws {
        // Create day subdirectory if needed
        let components = relativePath.components(separatedBy: "/")
        if components.count > 1 {
            let dayDir = videosDir.appendingPathComponent(components[0], isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        }

        let fullPath = videosDir.appendingPathComponent(relativePath)

        // Calculate output size (maintain aspect ratio, max 1024)
        let outputSize = calculateOutputSize(for: imageSize)

        // Create asset writer
        let writer = try AVAssetWriter(outputURL: fullPath, fileType: .mp4)

        // Configure video settings for H.265
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 500_000, // 500 kbps for 1 FPS screenshots
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: 1, // All keyframes for random access
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        // Create pixel buffer adaptor
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        writer.add(input)

        guard writer.startWriting() else {
            throw RewindError.storageError("Failed to start video writer: \(writer.error?.localizedDescription ?? "unknown error")")
        }

        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        videoInput = input
        pixelBufferAdaptor = adaptor

        log("VideoChunkEncoder: Started new chunk at \(relativePath)")
    }

    private func writeFrame(image: CGImage, frameIndex: Int) async throws {
        guard let adaptor = pixelBufferAdaptor,
              let input = videoInput
        else {
            throw RewindError.storageError("Video encoder not ready")
        }

        // Wait for input to be ready
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        // Create pixel buffer from CGImage
        guard let pixelBuffer = createPixelBuffer(from: image, adaptor: adaptor) else {
            throw RewindError.storageError("Failed to create pixel buffer")
        }

        // Calculate presentation time (1 FPS)
        let presentationTime = CMTime(value: Int64(frameIndex), timescale: CMTimeScale(frameRate))

        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw RewindError.storageError("Failed to append frame to video")
        }
    }

    private func finalizeCurrentChunk() async throws {
        guard let writer = assetWriter,
              let input = videoInput
        else {
            return
        }

        input.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if writer.status == .failed {
            logError("VideoChunkEncoder: Failed to finalize chunk: \(writer.error?.localizedDescription ?? "unknown")")
        } else {
            log("VideoChunkEncoder: Finalized chunk with \(frameBuffer.count) frames")
        }

        // Reset state
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        frameBuffer.removeAll()
        currentChunkStartTime = nil
        currentChunkPath = nil
        frameOffsetInChunk = 0
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

    private func createPixelBuffer(from image: CGImage, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // Draw the image, scaling to fit
        let targetSize = CGSize(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer)
        )

        context.draw(image, in: CGRect(origin: .zero, size: targetSize))

        return buffer
    }

    // MARK: - Cleanup

    /// Cancel any in-progress encoding and clean up
    func cancel() async {
        assetWriter?.cancelWriting()
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        frameBuffer.removeAll()
        currentChunkStartTime = nil
        currentChunkPath = nil
        frameOffsetInChunk = 0
    }
}

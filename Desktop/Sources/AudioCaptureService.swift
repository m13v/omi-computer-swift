import Foundation
import AVFoundation

/// Service for capturing microphone audio as 16-bit PCM at 16kHz
/// Suitable for streaming to speech-to-text services like DeepGram
class AudioCaptureService {

    // MARK: - Types

    /// Callback for receiving audio chunks
    typealias AudioChunkHandler = (Data) -> Void

    enum AudioCaptureError: LocalizedError {
        case noInputAvailable
        case engineStartFailed(Error)
        case permissionDenied
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .noInputAvailable:
                return "No audio input device available"
            case .engineStartFailed(let error):
                return "Failed to start audio engine: \(error.localizedDescription)"
            case .permissionDenied:
                return "Microphone permission denied"
            case .converterCreationFailed:
                return "Failed to create audio converter"
            }
        }
    }

    // MARK: - Properties

    private let audioEngine = AVAudioEngine()
    private var isCapturing = false
    private var onAudioChunk: AudioChunkHandler?

    /// Target sample rate for DeepGram
    private let targetSampleRate: Double = 16000

    // Resampling
    private var audioConverter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var detectedSampleRate: Double = 0.0

    // Device change handling
    private var configChangeObserver: NSObjectProtocol?
    private var isReconfiguring = false

    // MARK: - Public Methods

    /// Check if microphone permission is granted
    static func checkPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Request microphone permission
    static func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Start capturing audio from microphone
    /// - Parameter onAudioChunk: Callback receiving 16-bit PCM audio data chunks at 16kHz
    func startCapture(onAudioChunk: @escaping AudioChunkHandler) throws {
        guard !isCapturing else {
            log("AudioCapture: Already capturing")
            return
        }

        self.onAudioChunk = onAudioChunk

        let inputNode = audioEngine.inputNode

        // Get the hardware input format
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputAvailable
        }

        detectedSampleRate = hwFormat.sampleRate
        self.inputFormat = hwFormat

        log("AudioCapture: Hardware format - \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount) channels")

        // Create target format: Float32 at 16kHz mono (standard format)
        // We'll convert Float32 to Int16 manually for DeepGram
        guard let targetFmt = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.targetFormat = targetFmt

        log("AudioCapture: Target format - \(targetFmt.sampleRate)Hz, \(targetFmt.channelCount) channels, Float32")

        // Create audio converter for resampling
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFmt) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.audioConverter = converter

        // Install tap on input node
        let bufferSize: AVAudioFrameCount = 512
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }

        // Start the audio engine
        do {
            try audioEngine.start()
            isCapturing = true
            log("AudioCapture: Started capturing")
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error)
        }

        // Listen for audio device/configuration changes
        setupConfigurationChangeObserver()
    }

    /// Set up observer for audio configuration changes (device switches, format changes)
    private func setupConfigurationChangeObserver() {
        // Remove any existing observer
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            // IMPORTANT: Don't do work directly in callback - use async to avoid deadlock
            DispatchQueue.main.async {
                self?.handleConfigurationChange()
            }
        }
    }

    /// Handle audio configuration change (e.g., user switched microphone)
    private func handleConfigurationChange() {
        guard isCapturing, !isReconfiguring else { return }
        isReconfiguring = true

        log("AudioCapture: Configuration changed, restarting with new device...")

        // Save the current callback
        let savedCallback = onAudioChunk

        // Remove old tap (engine is already stopped by the system)
        audioEngine.inputNode.removeTap(onBus: 0)

        // Get the NEW hardware format (may have changed)
        let inputNode = audioEngine.inputNode
        let newHwFormat = inputNode.inputFormat(forBus: 0)

        guard newHwFormat.channelCount > 0 else {
            log("AudioCapture: No input available after config change")
            isReconfiguring = false
            return
        }

        log("AudioCapture: New hardware format - \(newHwFormat.sampleRate)Hz, \(newHwFormat.channelCount) channels")

        // Update stored format info
        detectedSampleRate = newHwFormat.sampleRate
        inputFormat = newHwFormat

        // Recreate converter with new input format
        guard let targetFmt = targetFormat,
              let newConverter = AVAudioConverter(from: newHwFormat, to: targetFmt) else {
            log("AudioCapture: Failed to create converter for new format")
            isReconfiguring = false
            return
        }
        audioConverter = newConverter

        // Reinstall tap with new format
        let bufferSize: AVAudioFrameCount = 512
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: newHwFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }

        // Restart the engine
        do {
            try audioEngine.start()
            log("AudioCapture: Restarted with new configuration")
        } catch {
            log("AudioCapture: Failed to restart after config change - \(error.localizedDescription)")
            // Try to restore callback for potential retry
            onAudioChunk = savedCallback
        }

        isReconfiguring = false
    }

    /// Stop capturing audio
    func stopCapture() {
        guard isCapturing else { return }

        // Remove configuration change observer
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
        isReconfiguring = false
        onAudioChunk = nil

        // Clean up converter
        audioConverter = nil
        inputFormat = nil
        targetFormat = nil
        detectedSampleRate = 0.0

        log("AudioCapture: Stopped capturing")
    }

    /// Check if currently capturing
    var capturing: Bool {
        return isCapturing
    }

    // MARK: - Private Methods

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isCapturing else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        guard let converter = audioConverter, let targetFmt = targetFormat else { return }

        // Calculate output buffer size based on sample rate conversion ratio
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(frameLength) * targetSampleRate / detectedSampleRate))

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outputFrameCapacity) else {
            return
        }

        // Convert using input block pattern (same as OMI Watch app)
        var error: NSError?
        var hasConsumedInput = false

        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if hasConsumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            hasConsumedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            log("AudioCapture: Conversion error - \(error.localizedDescription)")
            return
        }

        // Convert Float32 samples to Int16 (linear16 PCM for DeepGram)
        guard let channelData = outputBuffer.floatChannelData?[0] else {
            return
        }

        let processedFrameLength = Int(outputBuffer.frameLength)
        var pcmData = [Int16]()
        pcmData.reserveCapacity(processedFrameLength)

        for i in 0..<processedFrameLength {
            let sample = channelData[i]
            // Clamp and convert to Int16 range (-32768 to 32767)
            let pcmSample = Int16(max(-32768, min(32767, sample * 32767)))
            pcmData.append(pcmSample)
        }

        // Convert to Data (little-endian, which is native on Apple platforms)
        let byteData = pcmData.withUnsafeBufferPointer { buffer in
            return Data(buffer: buffer)
        }

        // Send to callback
        onAudioChunk?(byteData)
    }
}

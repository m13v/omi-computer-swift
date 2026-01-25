#!/usr/bin/env swift

import Foundation
import AVFoundation

// MARK: - Configuration

let DEEPGRAM_API_KEY: String = {
    // Try to load from .env files
    let envPaths = [
        "\(FileManager.default.currentDirectoryPath)/.env",
        "/Users/matthewdi/omi-computer-swift/.env",
        "/Users/matthewdi/omi/backend/.env"
    ]

    for path in envPaths {
        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines) {
                if line.hasPrefix("DEEPGRAM_API_KEY=") {
                    let key = String(line.dropFirst("DEEPGRAM_API_KEY=".count))
                        .trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\"", with: "")
                    print("✅ Found API key in: \(path)")
                    return key
                }
            }
        }
    }

    // Also check environment variable
    if let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] {
        print("✅ Found API key in environment")
        return key
    }

    print("❌ DEEPGRAM_API_KEY not found!")
    exit(1)
}()

// MARK: - Audio Capture

class AudioCapture {
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var detectedSampleRate: Double = 0.0

    var onAudioData: ((Data) -> Void)?

    func start() throws {
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.channelCount > 0 else {
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input"])
        }

        detectedSampleRate = hwFormat.sampleRate
        inputFormat = hwFormat

        log("🎤 Hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount) channels")

        // Create target format: Float32 at 16kHz mono
        guard let targetFmt = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
            throw NSError(domain: "AudioCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create target format"])
        }
        targetFormat = targetFmt

        log("🎯 Target format: \(targetFmt.sampleRate)Hz, 1 channel")

        // Create converter
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFmt) else {
            throw NSError(domain: "AudioCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create converter"])
        }
        audioConverter = converter

        // Install tap
        let bufferSize: AVAudioFrameCount = 512
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, time in
            self?.processBuffer(buffer)
        }

        try audioEngine.start()
        print("✅ Audio engine started")
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private var bufferCount = 0

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        guard let converter = audioConverter, let targetFmt = targetFormat else { return }

        // Calculate output buffer size
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(frameLength) * 16000 / detectedSampleRate))

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outputFrameCapacity) else {
            return
        }

        // Convert
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

        if error != nil { return }

        // Convert Float32 to Int16
        guard let channelData = outputBuffer.floatChannelData?[0] else { return }

        let processedFrameLength = Int(outputBuffer.frameLength)
        var pcmData = [Int16]()
        pcmData.reserveCapacity(processedFrameLength)

        var maxSample: Float = 0
        var minSample: Float = 0

        for i in 0..<processedFrameLength {
            let sample = channelData[i]
            maxSample = max(maxSample, sample)
            minSample = min(minSample, sample)
            let pcmSample = Int16(max(-32768, min(32767, sample * 32767)))
            pcmData.append(pcmSample)
        }

        let byteData = pcmData.withUnsafeBufferPointer { buffer in
            return Data(buffer: buffer)
        }

        // Log every 50 buffers (~1.6 seconds)
        if bufferCount % 50 == 0 {
            let amplitude = max(abs(minSample), abs(maxSample))
            let level = amplitude > 0.0001 ? 20 * log10(amplitude) : -80
            let levelStr = String(format: "%.1f", level)
            let bar = String(repeating: "█", count: max(0, min(20, Int((level + 60) / 3))))
            print("📊 Level: \(levelStr)dB \(bar)")
        }

        onAudioData?(byteData)
    }
}

// MARK: - WebSocket to DeepGram

class DeepgramConnection: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false

    // Audio buffering
    private var audioBuffer = Data()
    private let audioBufferSize = 3200  // ~100ms of 16kHz 16-bit audio
    private let audioBufferLock = NSLock()

    var onTranscript: ((String, Bool) -> Void)?
    var onConnected: (() -> Void)?

    func connect() {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "no_delay", value: "true"),
            URLQueryItem(name: "diarize", value: "false"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
            URLQueryItem(name: "vad_events", value: "true"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
        ]

        guard let url = components.url else {
            print("❌ Invalid URL")
            return
        }

        print("🔗 Connecting to DeepGram...")

        var request = URLRequest(url: url)
        request.setValue("Token \(DEEPGRAM_API_KEY)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: request)

        webSocketTask?.resume()
        receiveMessage()

        // Mark as connected after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.webSocketTask?.state == .running else { return }
            self.isConnected = true
            print("✅ Connected to DeepGram")
            self.startKeepalive()
            self.onConnected?()
        }
    }

    func disconnect() {
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    func sendAudio(_ data: Data) {
        guard isConnected else { return }

        audioBufferLock.lock()
        audioBuffer.append(data)

        if audioBuffer.count >= audioBufferSize {
            let chunk = audioBuffer
            audioBuffer = Data()
            audioBufferLock.unlock()

            guard let webSocketTask = webSocketTask else { return }

            let message = URLSessionWebSocketTask.Message.data(chunk)
            webSocketTask.send(message) { error in
                if let error = error {
                    print("❌ Send error: \(error)")
                }
            }
        } else {
            audioBufferLock.unlock()
        }
    }

    private func startKeepalive() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, self.isConnected else { return }
            self.sendKeepalive()
            self.startKeepalive()
        }
    }

    private func sendKeepalive() {
        guard isConnected, let webSocketTask = webSocketTask else { return }

        let keepalive = "{\"type\": \"KeepAlive\"}"
        let message = URLSessionWebSocketTask.Message.string(keepalive)
        webSocketTask.send(message) { _ in }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                self?.receiveMessage()
            case .failure(let error):
                print("❌ Receive error: \(error)")
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseResponse(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseResponse(text)
            }
        @unknown default:
            break
        }
    }

    private func parseResponse(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let type = json["type"] as? String {
                    if type == "Results" {
                        if let channel = json["channel"] as? [String: Any],
                           let alternatives = channel["alternatives"] as? [[String: Any]],
                           let first = alternatives.first,
                           let transcript = first["transcript"] as? String {
                            let isFinal = json["is_final"] as? Bool ?? false

                            if !transcript.isEmpty {
                                if isFinal {
                                    print("")
                                    print(">>> \(transcript)")
                                    print("")
                                } else {
                                    print("... \(transcript)")
                                }
                                onTranscript?(transcript, isFinal)
                            }
                        }
                    } else if type == "SpeechStarted" {
                        print("🗣️ Speech detected")
                    }
                }
            }
        } catch {
            // Ignore parse errors for metadata messages
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {}
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
    }
}

// MARK: - Unbuffered print
func log(_ message: String) {
    fputs(message + "\n", stderr)
    fflush(stderr)
}

// MARK: - Main

log("")
log("==================================================")
log("DeepGram Transcription Test")
log("==================================================")
log("")
log("⚠️  IMPORTANT: Make sure your audio input is set to")
log("    MacBook Pro Microphone (not AirPods/Bluetooth)")
log("")
log("    System Settings > Sound > Input")
log("")
log("--------------------------------------------------")

// Check microphone permission
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    log("✅ Microphone permission: authorized")
case .notDetermined:
    log("⏳ Requesting microphone permission...")
    let semaphore = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
            log("✅ Permission granted")
        } else {
            log("❌ Permission denied")
            exit(1)
        }
        semaphore.signal()
    }
    semaphore.wait()
case .denied, .restricted:
    log("❌ Microphone permission denied.")
    log("   Go to System Settings > Privacy & Security > Microphone")
    exit(1)
@unknown default:
    log("❌ Unknown permission status")
    exit(1)
}

let audioCapture = AudioCapture()
let deepgram = DeepgramConnection()

// Wire up audio to DeepGram
audioCapture.onAudioData = { data in
    deepgram.sendAudio(data)
}

// Connect to DeepGram
deepgram.connect()

// Wait for connection, then start audio
deepgram.onConnected = {
    log("")
    do {
        try audioCapture.start()
        log("")
        log("🎙️  Speak now! Press Ctrl+C to stop.")
        log("--------------------------------------------------")
        log("")
    } catch {
        log("❌ Failed to start audio: \(error)")
        exit(1)
    }
}

// Keep running
RunLoop.main.run()

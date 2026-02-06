# OMI Desktop CPU Analysis Report

**Date:** 2026-02-05
**Scope:** Full codebase audit of CPU-intensive operations

---

## Executive Summary

The most CPU-intensive operation is the **Screen Capture + Processing Pipeline** (frame capture, OCR, video encoding), which runs every 0.5-1s when monitoring is enabled. Secondary hotspots are audio codec decoding from BLE devices and audio resampling from microphone capture. Network polling at 3-second intervals is an unnecessary background CPU drain.

---

## Top CPU Consumers (Ranked)

### 1. SCREEN CAPTURE + PROCESSING PIPELINE — CRITICAL

The single most expensive operation. When monitoring is enabled, a timer fires every 0.5-1 second and triggers a multi-stage pipeline:

| Stage | File | Lines | Operation | Cost |
|-------|------|-------|-----------|------|
| Timer | ProactiveAssistantsPlugin.swift | 230-234 | Fires `captureFrame()` at `RewindSettings.shared.captureInterval` | Trigger |
| Window Info | ScreenCaptureService.swift | 234-352 | Accessibility API queries for focused window | Medium |
| Frame Capture | ScreenCaptureService.swift | 357-413 | ScreenCaptureKit capture + image scaling | **Very High** |
| JPEG Encode | ScreenCaptureService.swift | 498-517 | NSBitmapImageRep JPEG compression | High |
| Image Resize | ScreenCaptureService.swift | 483-495 | NSImage resize for storage | High |
| OCR | RewindOCRService.swift | 82-149 | Vision framework text recognition (accurate mode + language correction) | **Very High** |
| Video Encode | VideoChunkEncoder.swift | 83-200 | FFmpeg H.265 encoding, 60s chunks, subprocess I/O | **Very High** |
| Frame Distribution | ProactiveAssistantsPlugin.swift | 465 | Distributes to all assistants (Focus, Memory, Advice) | Medium |
| Focus Analysis | FocusAssistant.swift | 87-110 | `while isRunning` loop with 0.1s sleep, processes frames | Medium |

**Total per-frame cost:** ScreenCaptureKit + JPEG encode + OCR + H.265 encode = **extremely high**
**Frequency:** Every 0.5-1 second (configurable via `RewindSettings.shared.captureInterval`)
**When active:** Only when screen monitoring is enabled (user opt-in)

---

### 2. AUDIO CODEC DECODING (BLE Devices) — HIGH

When connected to a Bluetooth OMI device, incoming audio must be decoded in real-time.

| Codec | File | Lines | Cost per Frame | Notes |
|-------|------|-------|---------------|-------|
| Opus | AudioCodecDecoder.swift | 97-272 | **High** | AudioToolbox converter, 160-320 samples/frame |
| AAC | AudioCodecDecoder.swift | 274-435 | **Very High** | 1024 samples/frame, most complex codec |
| µ-law | AudioCodecDecoder.swift | 437-488 | Low | Lookup table, O(1) per sample |
| PCM | AudioCodecDecoder.swift | 48-95 | Negligible | Memory copy only |

**Frame reassembly:** BleAudioProcessor.swift:224-280 — multi-packet BLE frame reconstruction
**Frequency:** Per BLE audio frame (~100+ Hz when streaming)
**When active:** Only when BLE device connected and streaming audio

---

### 3. AUDIO CAPTURE & RESAMPLING — HIGH

Microphone and system audio capture with real-time format conversion.

| Operation | File | Lines | Cost | Frequency |
|-----------|------|-------|------|-----------|
| Audio tap | AudioCaptureService.swift | 99-155 | Medium | Per 512-sample buffer (~100Hz) |
| 48kHz→16kHz resample | AudioCaptureService.swift | 319-341 | **High** | Per buffer (~100Hz) |
| RMS level calc | AudioCaptureService.swift | 371-375 | Medium | Per buffer (~100Hz) |
| Float32→Int16 conversion | AudioCaptureService.swift | 356-361 | Medium | Per buffer |
| System audio capture | SystemAudioCaptureService.swift | 93-191 | **High** | Per I/O callback |
| Stereo→mono mix | SystemAudioCaptureService.swift | 262-276 | Medium | Per I/O callback |
| Stereo interleave | AudioMixer.swift | 149-176 | Medium | Per 100ms chunk (~10Hz) |

**When active:** During recording (microphone always; system audio if enabled)

---

### 4. NETWORK POLLING — MEDIUM-HIGH (Wasteful)

Multiple 3-second polling timers that make API calls or DB queries:

| Component | File | Line | Interval | Work |
|-----------|------|------|----------|------|
| TasksAutoRefresh | TasksStore.swift | 123 | **3 seconds** | `getActionItems()` API call |
| MemoriesAutoRefresh | MemoriesPage.swift | 166 | **3 seconds** | Memories API call |
| RewindAutoRefresh | RewindViewModel.swift | 85 | **3 seconds** | DB query for today's screenshots |

**Note:** TasksStore may run even when the page is not visible. All three involve JSON parsing + network/DB I/O.

---

### 5. RESOURCE MONITOR — MEDIUM

| Operation | File | Lines | Interval |
|-----------|------|-------|----------|
| Thread enumeration | ResourceMonitor.swift | 260-291 | 30 seconds |
| Memory sampling | ResourceMonitor.swift | 217-248 | 30 seconds |
| Memory pressure | ResourceMonitor.swift | 346-368 | 30 seconds |

Uses `task_threads()` → iterates all threads → `thread_info()` per thread. O(t) where t = thread count (typically 30-100).

---

### 6. FORCE-DIRECTED GRAPH SIMULATION — MEDIUM (Conditional)

| Operation | File | Lines | Notes |
|-----------|------|-------|-------|
| Repulsive forces | ForceDirectedSimulation.swift | 112-138 | **O(n²)** between all nodes |
| Attractive forces | ForceDirectedSimulation.swift | 141-150+ | Per edge |
| Optimization | ForceDirectedSimulation.swift | 109 | Only runs every 4th tick |

**When active:** Only when Memory Graph view is visible. Scales quadratically with node count.

---

### 7. TRANSCRIPTION SERVICE — LOW-MEDIUM

| Operation | File | Lines | Notes |
|-----------|------|-------|-------|
| Audio buffering | TranscriptionService.swift | 139-180 | 3200-byte chunks (~100ms) |
| WebSocket send | TranscriptionService.swift | 170-180 | Network I/O |
| JSON parsing | TranscriptionService.swift | 345-411 | Per transcript response |
| Keepalive | TranscriptionService.swift | 250-260 | 8-second ping loop |

Speech recognition itself is **cloud-based** (DeepGram nova-3). No local ML models.

---

## Always-On Background Operations

These run continuously regardless of user activity:

| Operation | Interval | CPU Impact |
|-----------|----------|-----------|
| Sentry Heartbeat (OmiApp.swift:223) | 300s | Low |
| Resource Monitor (ResourceMonitor.swift:56) | 30s | Medium |
| Transcription Retry (TranscriptionRetryService.swift:23) | 60s | Low-Medium |
| Tasks Auto-Refresh (TasksStore.swift:123) | 3s | Medium-High |

---

## All Timers Inventory

| Timer | File | Interval | Always On? | CPU Impact |
|-------|------|----------|-----------|-----------|
| Screen Capture | ProactiveAssistantsPlugin.swift:230 | 0.5-1s | No (monitoring) | **CRITICAL** |
| Tasks Refresh | TasksStore.swift:123 | 3s | Yes* | Medium-High |
| Memories Refresh | MemoriesPage.swift:166 | 3s | No (page visible) | Medium |
| Rewind Refresh | RewindViewModel.swift:85 | 3s | No (page visible) | Medium |
| Resource Monitor | ResourceMonitor.swift:56 | 30s | Yes | Medium |
| Transcription Retry | TranscriptionRetryService.swift:23 | 60s | Yes | Low-Medium |
| WAL Chunk | WALService.swift:206 | 75s | No (recording) | Low |
| WAL Flush | WALService.swift:214 | 105s | No (recording) | Low-Medium |
| Sentry Heartbeat | OmiApp.swift:223 | 300s | Yes | Low |
| Recording Timer | RecordingTimer.swift:23 | 1s | No (recording) | Low |
| Onboarding Timer | OnboardingView.swift:21 | 1s | No (onboarding) | Low |
| Focus Countdown | FocusPage.swift:91 | 1s | No (FocusPage) | Low |
| Device Reconnect | DeviceProvider.swift:332 | ~5-10s | No (disconnect) | Low-Medium |
| BLE Scan Timeout | BluetoothManager.swift:80 | 5s | No (scanning) | Low |

---

## Architecture Note

The app uses a **cloud-first architecture** for speech recognition:
- **No local ML models** (no CoreML, no Whisper, no local VAD)
- All transcription via DeepGram WebSocket API (nova-3 model)
- VAD is server-side (`endpointing=300`, `vad_events=true`)
- Local CPU is dominated by **screen capture pipeline** and **audio I/O**, not ML inference

---

## Optimization Opportunities

1. **Screen capture pipeline**: OCR + H.265 encoding are the biggest CPU consumers. Consider:
   - Skip OCR on frames with no visual change (diff detection before OCR)
   - Reduce capture frequency when idle
   - Use GPU-accelerated OCR or VideoToolbox for H.265

2. **3-second polling timers**: Replace with push notifications or longer intervals
   - TasksStore polling is especially wasteful if the page isn't visible

3. **Audio resampling**: Consider requesting 16kHz directly from hardware if supported

4. **Force-directed simulation**: Use Barnes-Hut approximation for O(n log n) instead of O(n²)

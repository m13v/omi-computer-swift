import Foundation

/// Stored focus session with additional metadata
struct StoredFocusSession: Codable, Identifiable {
    let id: String
    let status: FocusStatus
    let appOrSite: String
    let description: String
    let message: String?
    let createdAt: Date
    let durationSeconds: Int?
    let isSynced: Bool

    init(
        id: String = UUID().uuidString,
        status: FocusStatus,
        appOrSite: String,
        description: String,
        message: String? = nil,
        createdAt: Date = Date(),
        durationSeconds: Int? = nil,
        isSynced: Bool = false
    ) {
        self.id = id
        self.status = status
        self.appOrSite = appOrSite
        self.description = description
        self.message = message
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.isSynced = isSynced
    }

    func withSynced(_ synced: Bool) -> StoredFocusSession {
        StoredFocusSession(
            id: id,
            status: status,
            appOrSite: appOrSite,
            description: description,
            message: message,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            isSynced: synced
        )
    }
}

/// Focus statistics for a day
struct FocusDayStats {
    let date: Date
    let focusedMinutes: Int
    let distractedMinutes: Int
    let sessionCount: Int
    let focusedCount: Int
    let distractedCount: Int
    let topDistractions: [(appOrSite: String, totalSeconds: Int, count: Int)]

    /// Focus rate as a percentage (0-100)
    var focusRate: Double {
        let total = focusedCount + distractedCount
        guard total > 0 else { return 0 }
        return Double(focusedCount) / Double(total) * 100
    }
}

/// Local storage manager for focus session history
@MainActor
class FocusStorage: ObservableObject {
    static let shared = FocusStorage()

    @Published private(set) var sessions: [StoredFocusSession] = []
    @Published private(set) var currentStatus: FocusStatus?
    @Published private(set) var currentApp: String?

    // MARK: - Real-time Status Properties

    /// The currently detected app (updated immediately on app switch, before analysis)
    @Published private(set) var detectedAppName: String?

    /// When the analysis delay period will end (nil if not in delay)
    @Published private(set) var delayEndTime: Date?

    /// When the analysis cooldown period will end (nil if not in cooldown)
    @Published private(set) var cooldownEndTime: Date?

    private let storageKey = "omi.focus.sessions"
    private let maxStoredSessions = 500

    private init() {
        loadFromStorage()
    }

    // MARK: - Real-time Status Updates

    /// Update the detected app name (called immediately on app switch)
    func updateDetectedApp(_ appName: String?) {
        detectedAppName = appName
    }

    /// Update the delay end time (called when delay period starts/ends)
    func updateDelayEndTime(_ endTime: Date?) {
        delayEndTime = endTime
    }

    /// Update the cooldown end time (called by FocusAssistant when cooldown starts/ends)
    func updateCooldownEndTime(_ endTime: Date?) {
        cooldownEndTime = endTime
    }

    /// Clear all real-time status (called when monitoring stops)
    func clearRealtimeStatus() {
        detectedAppName = nil
        delayEndTime = nil
        cooldownEndTime = nil
    }

    // MARK: - Public Methods

    /// Add a new session from screen analysis
    func addSession(from analysis: ScreenAnalysis) {
        let session = StoredFocusSession(
            status: analysis.status,
            appOrSite: analysis.appOrSite,
            description: analysis.description,
            message: analysis.message
        )

        sessions.insert(session, at: 0)

        // Update current status
        currentStatus = analysis.status
        currentApp = analysis.appOrSite

        // Trim if needed
        if sessions.count > maxStoredSessions {
            sessions = Array(sessions.prefix(maxStoredSessions))
        }

        saveToStorage()

        // Sync to backend in background
        Task {
            await syncSession(session)
        }
    }

    /// Get today's sessions
    var todaySessions: [StoredFocusSession] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return sessions.filter { calendar.isDate($0.createdAt, inSameDayAs: today) }
    }

    /// Get today's statistics
    var todayStats: FocusDayStats {
        let todayList = todaySessions

        var focusedCount = 0
        var distractedCount = 0
        var distractionMap: [String: (seconds: Int, count: Int)] = [:]

        for session in todayList {
            switch session.status {
            case .focused:
                focusedCount += 1
            case .distracted:
                distractedCount += 1
                let current = distractionMap[session.appOrSite] ?? (0, 0)
                let seconds = session.durationSeconds ?? 60
                distractionMap[session.appOrSite] = (current.seconds + seconds, current.count + 1)
            }
        }

        // Build top distractions
        let topDistractions = distractionMap
            .map { (appOrSite: $0.key, totalSeconds: $0.value.seconds, count: $0.value.count) }
            .sorted { $0.totalSeconds > $1.totalSeconds }
            .prefix(5)

        return FocusDayStats(
            date: Date(),
            focusedMinutes: focusedCount,
            distractedMinutes: distractedCount,
            sessionCount: todayList.count,
            focusedCount: focusedCount,
            distractedCount: distractedCount,
            topDistractions: Array(topDistractions)
        )
    }

    /// Delete a session
    func deleteSession(_ id: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            let session = sessions[index]
            sessions.remove(at: index)
            saveToStorage()

            // Delete from backend
            if session.isSynced {
                Task {
                    await deleteFromBackend(id)
                }
            }
        }
    }

    /// Clear all sessions
    func clearAll() {
        sessions = []
        currentStatus = nil
        currentApp = nil
        saveToStorage()
    }

    /// Get sessions for a specific date
    func sessions(for date: Date) -> [StoredFocusSession] {
        let calendar = Calendar.current
        return sessions.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
    }

    /// Fetch focus sessions from backend (stored as memories with "focus" tag) and merge
    func refreshFromBackend() async {
        do {
            // Fetch memories that have the "focus" tag
            let focusMemories = try await APIClient.shared.getMemories(
                limit: 100,
                tags: ["focus"]
            )

            await MainActor.run {
                // Merge backend memories with local sessions
                var mergedIds = Set<String>()
                var merged: [StoredFocusSession] = []

                // Add backend memories first (they are authoritative)
                for memory in focusMemories {
                    mergedIds.insert(memory.id)

                    // Parse status from tags
                    let status: FocusStatus = memory.tags.contains("focused") ? .focused : .distracted

                    // Parse app name from tags (look for "app:*" tag)
                    let appOrSite = memory.tags
                        .first { $0.hasPrefix("app:") }
                        .map { String($0.dropFirst(4)) } ?? memory.sourceApp ?? "Unknown"

                    merged.append(StoredFocusSession(
                        id: memory.id,
                        status: status,
                        appOrSite: appOrSite,
                        description: memory.content,
                        message: nil,  // Message not stored separately in memory
                        createdAt: memory.createdAt,
                        durationSeconds: nil,
                        isSynced: true
                    ))
                }

                // Add local sessions that weren't synced
                for local in self.sessions where !mergedIds.contains(local.id) && !local.isSynced {
                    merged.append(local)
                }

                // Sort by date
                merged.sort { $0.createdAt > $1.createdAt }

                self.sessions = Array(merged.prefix(self.maxStoredSessions))
                self.saveToStorage()
            }
        } catch {
            logError("Failed to refresh focus memories from backend", error: error)
        }
    }

    // MARK: - Private Methods

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([StoredFocusSession].self, from: data)

            // Update current status from most recent session
            if let latest = sessions.first {
                currentStatus = latest.status
                currentApp = latest.appOrSite
            }
        } catch {
            logError("Failed to load focus sessions", error: error)
        }
    }

    private func saveToStorage() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            logError("Failed to save focus sessions", error: error)
        }
    }

    private func syncSession(_ session: StoredFocusSession) async {
        do {
            // Build content for the memory
            let statusText = session.status == .focused ? "Focused" : "Distracted"
            let content = "\(statusText) on \(session.appOrSite): \(session.description)"

            // Build tags: ["focus", "focused"/"distracted", "app:{appName}"]
            let statusTag = session.status == .focused ? "focused" : "distracted"
            let appTag = "app:\(session.appOrSite)"
            var tags = ["focus", statusTag, appTag]

            // Add message as additional context if present
            if let message = session.message, !message.isEmpty {
                tags.append("has-message")
            }

            let response = try await APIClient.shared.createMemory(
                content: content,
                visibility: "private",
                category: .system,
                tags: tags,
                source: "desktop"
            )

            // Mark as synced with the backend memory ID
            await MainActor.run {
                if let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
                    // Update the session with backend ID for future reference
                    let syncedSession = StoredFocusSession(
                        id: response.id,  // Use backend ID
                        status: session.status,
                        appOrSite: session.appOrSite,
                        description: session.description,
                        message: session.message,
                        createdAt: session.createdAt,
                        durationSeconds: session.durationSeconds,
                        isSynced: true
                    )
                    self.sessions[index] = syncedSession
                    self.saveToStorage()
                }
            }
        } catch {
            logError("Failed to sync focus session as memory to backend", error: error)
        }
    }

    private func deleteFromBackend(_ id: String) async {
        do {
            // Focus sessions are now stored as memories, so delete the memory
            try await APIClient.shared.deleteMemory(id: id)
        } catch {
            logError("Failed to delete focus memory from backend", error: error)
        }
    }
}

// MARK: - API Models

struct CreateFocusSessionRequest: Codable {
    let status: String
    let appOrSite: String
    let description: String
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case appOrSite = "app_or_site"
        case description
        case message
    }
}

struct FocusSessionResponse: Codable {
    let id: String
    let status: String
    let appOrSite: String
    let description: String
    let message: String?
    let createdAt: Date
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case appOrSite = "app_or_site"
        case description
        case message
        case createdAt = "created_at"
        case durationSeconds = "duration_seconds"
    }
}

struct FocusStatsResponse: Codable {
    let date: String
    let focusedMinutes: Int
    let distractedMinutes: Int
    let sessionCount: Int
    let focusedCount: Int
    let distractedCount: Int
    let topDistractions: [DistractionEntryResponse]

    enum CodingKeys: String, CodingKey {
        case date
        case focusedMinutes = "focused_minutes"
        case distractedMinutes = "distracted_minutes"
        case sessionCount = "session_count"
        case focusedCount = "focused_count"
        case distractedCount = "distracted_count"
        case topDistractions = "top_distractions"
    }
}

struct DistractionEntryResponse: Codable {
    let appOrSite: String
    let totalSeconds: Int
    let count: Int

    enum CodingKeys: String, CodingKey {
        case appOrSite = "app_or_site"
        case totalSeconds = "total_seconds"
        case count
    }
}

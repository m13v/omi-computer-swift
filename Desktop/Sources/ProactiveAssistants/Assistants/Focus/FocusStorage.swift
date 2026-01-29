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

    private let storageKey = "omi.focus.sessions"
    private let maxStoredSessions = 500

    private init() {
        loadFromStorage()
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
            .map { $0 }

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

    /// Fetch sessions from backend and merge
    func refreshFromBackend() async {
        do {
            let backendSessions: [FocusSessionResponse] = try await APIClient.shared.getFocusSessions(limit: 100, date: nil)

            await MainActor.run {
                // Merge backend sessions with local ones
                var mergedIds = Set<String>()
                var merged: [StoredFocusSession] = []

                // Add backend sessions first (they are authoritative)
                for remote in backendSessions {
                    mergedIds.insert(remote.id)
                    merged.append(StoredFocusSession(
                        id: remote.id,
                        status: remote.status == "focused" ? .focused : .distracted,
                        appOrSite: remote.appOrSite,
                        description: remote.description,
                        message: remote.message,
                        createdAt: remote.createdAt,
                        durationSeconds: remote.durationSeconds,
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
            logError("Failed to refresh focus sessions from backend", error: error)
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
            let request = CreateFocusSessionRequest(
                status: session.status == .focused ? "focused" : "distracted",
                appOrSite: session.appOrSite,
                description: session.description,
                message: session.message
            )

            let _: FocusSessionResponse = try await APIClient.shared.createFocusSession(request)

            // Mark as synced
            await MainActor.run {
                if let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
                    self.sessions[index] = session.withSynced(true)
                    self.saveToStorage()
                }
            }
        } catch {
            logError("Failed to sync focus session to backend", error: error)
        }
    }

    private func deleteFromBackend(_ id: String) async {
        do {
            try await APIClient.shared.deleteFocusSession(id)
        } catch {
            logError("Failed to delete focus session from backend", error: error)
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

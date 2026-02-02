import Foundation

/// Stored advice item with additional metadata
struct StoredAdvice: Codable, Identifiable {
    let id: String
    let advice: ExtractedAdvice
    let contextSummary: String
    let currentActivity: String
    let createdAt: Date
    var isRead: Bool
    var isDismissed: Bool

    init(
        id: String = UUID().uuidString,
        advice: ExtractedAdvice,
        contextSummary: String,
        currentActivity: String,
        createdAt: Date = Date(),
        isRead: Bool = false,
        isDismissed: Bool = false
    ) {
        self.id = id
        self.advice = advice
        self.contextSummary = contextSummary
        self.currentActivity = currentActivity
        self.createdAt = createdAt
        self.isRead = isRead
        self.isDismissed = isDismissed
    }

    /// Convert from server model
    init(from serverAdvice: ServerAdvice) {
        self.id = serverAdvice.id
        self.advice = ExtractedAdvice(
            advice: serverAdvice.content,
            reasoning: serverAdvice.reasoning,
            category: serverAdvice.category.toLocal,
            sourceApp: serverAdvice.sourceApp ?? "Unknown",
            confidence: serverAdvice.confidence
        )
        self.contextSummary = serverAdvice.contextSummary ?? ""
        self.currentActivity = serverAdvice.currentActivity ?? ""
        self.createdAt = serverAdvice.createdAt
        self.isRead = serverAdvice.isRead
        self.isDismissed = serverAdvice.isDismissed
    }

    func withRead(_ read: Bool) -> StoredAdvice {
        var copy = self
        copy.isRead = read
        return copy
    }

    func withDismissed(_ dismissed: Bool) -> StoredAdvice {
        var copy = self
        copy.isDismissed = dismissed
        return copy
    }
}

/// Local storage manager for advice history with backend sync
@MainActor
class AdviceStorage: ObservableObject {
    static let shared = AdviceStorage()

    @Published private(set) var adviceHistory: [StoredAdvice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastSyncError: String?

    private let localStorageKey = "omi.advice.history"
    private let maxLocalAdvice = 100
    private var isSyncing = false

    private init() {
        // Load from local cache first for immediate display
        loadFromLocalCache()

        // Then sync with backend
        Task {
            await syncFromBackend()
        }
    }

    // MARK: - Public Methods

    /// Add new advice to storage and sync to backend
    func addAdvice(_ result: AdviceExtractionResult) {
        guard let advice = result.advice else { return }

        // Create local stored advice
        let storedAdvice = StoredAdvice(
            advice: advice,
            contextSummary: result.contextSummary,
            currentActivity: result.currentActivity
        )

        // Add locally first for immediate UI update
        adviceHistory.insert(storedAdvice, at: 0)
        trimLocalCache()
        saveToLocalCache()

        // Sync to backend
        Task {
            await createAdviceOnBackend(storedAdvice)
        }
    }

    /// Mark advice as read
    func markAsRead(_ id: String) {
        guard let index = adviceHistory.firstIndex(where: { $0.id == id }) else { return }

        adviceHistory[index] = adviceHistory[index].withRead(true)
        saveToLocalCache()

        // Sync to backend
        Task {
            await updateAdviceOnBackend(id: id, isRead: true, isDismissed: nil)
        }
    }

    /// Mark all advice as read
    func markAllAsRead() {
        adviceHistory = adviceHistory.map { $0.withRead(true) }
        saveToLocalCache()

        // Sync to backend
        Task {
            await markAllReadOnBackend()
        }
    }

    /// Dismiss advice (hide from list)
    func dismissAdvice(_ id: String) {
        guard let index = adviceHistory.firstIndex(where: { $0.id == id }) else { return }

        adviceHistory[index] = adviceHistory[index].withDismissed(true)
        saveToLocalCache()

        // Sync to backend
        Task {
            await updateAdviceOnBackend(id: id, isRead: nil, isDismissed: true)
        }
    }

    /// Delete advice permanently
    func deleteAdvice(_ id: String) {
        adviceHistory.removeAll { $0.id == id }
        saveToLocalCache()

        // Sync to backend
        Task {
            await deleteAdviceOnBackend(id: id)
        }
    }

    /// Clear all advice history
    func clearAll() {
        let idsToDelete = adviceHistory.map { $0.id }
        adviceHistory = []
        saveToLocalCache()

        // Delete all from backend
        Task {
            for id in idsToDelete {
                await deleteAdviceOnBackend(id: id)
            }
        }
    }

    /// Refresh from backend
    func refresh() async {
        await syncFromBackend()
    }

    /// Get unread count
    var unreadCount: Int {
        adviceHistory.filter { !$0.isRead && !$0.isDismissed }.count
    }

    /// Get visible advice (not dismissed)
    var visibleAdvice: [StoredAdvice] {
        adviceHistory.filter { !$0.isDismissed }
    }

    // MARK: - Backend Sync

    private func syncFromBackend() async {
        guard !isSyncing else { return }
        isSyncing = true
        isLoading = true
        lastSyncError = nil

        do {
            let serverAdvice = try await APIClient.shared.getAdvice(
                limit: maxLocalAdvice,
                includeDismissed: true
            )

            // Convert to local model
            let localAdvice = serverAdvice.map { StoredAdvice(from: $0) }

            // Update local cache
            await MainActor.run {
                self.adviceHistory = localAdvice
                self.saveToLocalCache()
                self.isLoading = false
            }

            log("Advice: Synced \(localAdvice.count) items from backend")
        } catch {
            await MainActor.run {
                self.lastSyncError = error.localizedDescription
                self.isLoading = false
            }
            logError("Advice: Failed to sync from backend", error: error)
        }

        isSyncing = false
    }

    private func createAdviceOnBackend(_ advice: StoredAdvice) async {
        do {
            // Build tags: ["tips", "<category>"]
            let categoryTag = advice.advice.category.rawValue.lowercased()
            let tags = ["tips", categoryTag]

            // Create as memory with tags instead of separate advice
            // source = "screenshot" since tips come from screen capture
            let response = try await APIClient.shared.createMemory(
                content: advice.advice.advice,
                visibility: "private",
                category: .system, // Tips are stored as system category with tags
                confidence: advice.advice.confidence,
                sourceApp: advice.advice.sourceApp,
                contextSummary: advice.contextSummary,
                tags: tags,
                reasoning: advice.advice.reasoning,
                currentActivity: advice.currentActivity,
                source: "screenshot"
            )

            log("Advice: Created as memory with tags \(tags), source=screenshot, ID: \(response.id)")
        } catch {
            logError("Advice: Failed to create on backend", error: error)
        }
    }

    private func updateAdviceOnBackend(id: String, isRead: Bool?, isDismissed: Bool?) async {
        do {
            _ = try await APIClient.shared.updateAdvice(id: id, isRead: isRead, isDismissed: isDismissed)
            log("Advice: Updated on backend (id=\(id), isRead=\(String(describing: isRead)), isDismissed=\(String(describing: isDismissed)))")
        } catch {
            logError("Advice: Failed to update on backend", error: error)
        }
    }

    private func deleteAdviceOnBackend(id: String) async {
        do {
            try await APIClient.shared.deleteAdvice(id: id)
            log("Advice: Deleted from backend (id=\(id))")
        } catch {
            logError("Advice: Failed to delete from backend", error: error)
        }
    }

    private func markAllReadOnBackend() async {
        do {
            try await APIClient.shared.markAllAdviceAsRead()
            log("Advice: Marked all as read on backend")
        } catch {
            logError("Advice: Failed to mark all as read on backend", error: error)
        }
    }

    // MARK: - Local Cache

    private func loadFromLocalCache() {
        guard let data = UserDefaults.standard.data(forKey: localStorageKey) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            adviceHistory = try decoder.decode([StoredAdvice].self, from: data)
        } catch {
            logError("Failed to load advice from local cache", error: error)
        }
    }

    private func saveToLocalCache() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(adviceHistory)
            UserDefaults.standard.set(data, forKey: localStorageKey)
        } catch {
            logError("Failed to save advice to local cache", error: error)
        }
    }

    private func trimLocalCache() {
        if adviceHistory.count > maxLocalAdvice {
            adviceHistory = Array(adviceHistory.prefix(maxLocalAdvice))
        }
    }
}

// MARK: - AdviceCategory Extensions

extension AdviceCategory: CaseIterable {
    public static var allCases: [AdviceCategory] {
        [.productivity, .health, .communication, .learning, .other]
    }

    var displayName: String {
        switch self {
        case .productivity: return "Productivity"
        case .health: return "Health"
        case .communication: return "Communication"
        case .learning: return "Learning"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .productivity: return "chart.line.uptrend.xyaxis"
        case .health: return "heart.fill"
        case .communication: return "bubble.left.and.bubble.right.fill"
        case .learning: return "book.fill"
        case .other: return "lightbulb.fill"
        }
    }
}

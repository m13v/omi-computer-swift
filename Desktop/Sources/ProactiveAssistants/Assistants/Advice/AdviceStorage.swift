import Foundation

/// Stored advice item with additional metadata
struct StoredAdvice: Codable, Identifiable {
    let id: String
    let advice: ExtractedAdvice
    let contextSummary: String
    let currentActivity: String
    let createdAt: Date
    let isRead: Bool
    let isDismissed: Bool

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

    func withRead(_ read: Bool) -> StoredAdvice {
        StoredAdvice(
            id: id,
            advice: advice,
            contextSummary: contextSummary,
            currentActivity: currentActivity,
            createdAt: createdAt,
            isRead: read,
            isDismissed: isDismissed
        )
    }

    func withDismissed(_ dismissed: Bool) -> StoredAdvice {
        StoredAdvice(
            id: id,
            advice: advice,
            contextSummary: contextSummary,
            currentActivity: currentActivity,
            createdAt: createdAt,
            isRead: isRead,
            isDismissed: dismissed
        )
    }
}

/// Local storage manager for advice history
@MainActor
class AdviceStorage: ObservableObject {
    static let shared = AdviceStorage()

    @Published private(set) var adviceHistory: [StoredAdvice] = []

    private let storageKey = "omi.advice.history"
    private let maxStoredAdvice = 100

    private init() {
        loadFromStorage()
    }

    // MARK: - Public Methods

    /// Add new advice to storage
    func addAdvice(_ result: AdviceExtractionResult) {
        guard let advice = result.advice else { return }

        let storedAdvice = StoredAdvice(
            advice: advice,
            contextSummary: result.contextSummary,
            currentActivity: result.currentActivity
        )

        adviceHistory.insert(storedAdvice, at: 0)

        // Trim if needed
        if adviceHistory.count > maxStoredAdvice {
            adviceHistory = Array(adviceHistory.prefix(maxStoredAdvice))
        }

        saveToStorage()
    }

    /// Mark advice as read
    func markAsRead(_ id: String) {
        if let index = adviceHistory.firstIndex(where: { $0.id == id }) {
            adviceHistory[index] = adviceHistory[index].withRead(true)
            saveToStorage()
        }
    }

    /// Mark all advice as read
    func markAllAsRead() {
        adviceHistory = adviceHistory.map { $0.withRead(true) }
        saveToStorage()
    }

    /// Dismiss advice (hide from list)
    func dismissAdvice(_ id: String) {
        if let index = adviceHistory.firstIndex(where: { $0.id == id }) {
            adviceHistory[index] = adviceHistory[index].withDismissed(true)
            saveToStorage()
        }
    }

    /// Delete advice permanently
    func deleteAdvice(_ id: String) {
        adviceHistory.removeAll { $0.id == id }
        saveToStorage()
    }

    /// Clear all advice history
    func clearAll() {
        adviceHistory = []
        saveToStorage()
    }

    /// Get unread count
    var unreadCount: Int {
        adviceHistory.filter { !$0.isRead && !$0.isDismissed }.count
    }

    /// Get visible advice (not dismissed)
    var visibleAdvice: [StoredAdvice] {
        adviceHistory.filter { !$0.isDismissed }
    }

    // MARK: - Private Methods

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            adviceHistory = try decoder.decode([StoredAdvice].self, from: data)
        } catch {
            logError("Failed to load advice history", error: error)
        }
    }

    private func saveToStorage() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(adviceHistory)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            logError("Failed to save advice history", error: error)
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

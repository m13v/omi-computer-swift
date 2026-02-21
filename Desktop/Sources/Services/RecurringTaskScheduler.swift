import Foundation

/// Checks every 60 seconds for recurring tasks that are due.
/// Background investigation was removed — this scheduler currently only logs due tasks.
@MainActor
class RecurringTaskScheduler {
    static let shared = RecurringTaskScheduler()

    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        log("RecurringTaskScheduler: Starting (60s interval)")
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkDueTasks()
            }
        }
        // Also run immediately on start
        Task { await checkDueTasks() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        log("RecurringTaskScheduler: Stopped")
    }

    private func checkDueTasks() async {
        guard AuthState.shared.isSignedIn else { return }

        guard let tasks = try? await ActionItemStorage.shared.getDueRecurringTasks(),
              !tasks.isEmpty else { return }

        log("RecurringTaskScheduler: Found \(tasks.count) due recurring task(s)")
    }
}

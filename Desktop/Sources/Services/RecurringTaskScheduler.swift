import Foundation

/// Checks every 60 seconds for recurring tasks that are due and triggers
/// AI chat investigations for each one via TaskChatCoordinator (ACP bridge).
/// Dedup is automatic — investigateInBackground skips tasks with existing messages.
@MainActor
class RecurringTaskScheduler {
    static let shared = RecurringTaskScheduler()

    private var timer: Timer?
    private let coordinator: TaskChatCoordinator

    private init() {
        let provider = ChatProvider()
        coordinator = TaskChatCoordinator(chatProvider: provider)
    }

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
        for task in tasks {
            await coordinator.investigateInBackground(for: task)
        }
    }
}

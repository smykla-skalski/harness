import Foundation

final class LegacyManagedLaunchAgentContainment: @unchecked Sendable {
  private let lock = NSLock()
  private let interval: Duration
  private var task: Task<Void, Never>?

  init(interval: Duration = .seconds(1)) {
    self.interval = interval
  }

  func start(controller: any DaemonControlling) {
    lock.withLock {
      guard task == nil else { return }
      let interval = interval
      task = Task.detached(priority: .background) {
        var lastFailure: String?
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: interval)
          } catch {
            return
          }
          do {
            try await controller.requireLegacyManagedLaunchAgentCleanup()
            lastFailure = nil
          } catch is CancellationError {
            return
          } catch {
            let message = error.localizedDescription
            if message != lastFailure {
              HarnessMonitorLogger.lifecycle.fault(
                "Legacy daemon containment remains active: \(message, privacy: .public)"
              )
              lastFailure = message
            }
          }
        }
      }
    }
  }

  func cancel() {
    let task = lock.withLock {
      let activeTask = self.task
      self.task = nil
      return activeTask
    }
    task?.cancel()
  }

  deinit {
    task?.cancel()
  }
}

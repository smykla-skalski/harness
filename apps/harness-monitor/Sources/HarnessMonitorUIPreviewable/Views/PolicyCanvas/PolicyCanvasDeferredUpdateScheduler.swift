import Foundation

@MainActor
final class PolicyCanvasDeferredUpdateScheduler {
  private var task: Task<Void, Never>?

  func schedule(_ operation: @escaping @MainActor () async -> Void) {
    task?.cancel()
    task = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled else {
        return
      }
      await operation()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

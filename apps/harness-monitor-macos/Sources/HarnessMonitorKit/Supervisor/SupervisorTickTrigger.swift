import Foundation

@MainActor
final class SupervisorTickTrigger {
  var task: Task<Void, Never>?
  var pending = false
  var requestCount = 0
  var drainCount = 0
  var latestReason: String?

  func cancel() {
    task?.cancel()
    task = nil
    pending = false
    latestReason = nil
  }
}

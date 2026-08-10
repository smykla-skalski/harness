@testable import HarnessMonitorKit

enum TaskBoardFallbackSurface: Sendable {
  case host
  case settings
}

actor LegacyContainmentCapabilitiesGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private(set) var hasEntered = false

  func wait() async -> TaskBoardCapabilities {
    hasEntered = true
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
    return TaskBoardCapabilities(
      storage: "database",
      revision: 0,
      instanceID: "recording-task-board"
    )
  }

  func release() {
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting {
      continuation.resume()
    }
  }
}

actor LegacyContainmentRegistrationAttempt {
  private var attempt = 0

  func run() throws {
    attempt += 1
    if attempt == 1 {
      throw DaemonControlError.legacyManagedLaunchAgentCleanupFailed
    }
  }
}

actor LegacyContainmentWarmUpGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private(set) var hasEntered = false

  func wait() async {
    hasEntered = true
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func release() {
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting {
      continuation.resume()
    }
  }
}

actor LegacyContainmentVoidGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private(set) var hasEntered = false

  func wait() async {
    hasEntered = true
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func release() {
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting {
      continuation.resume()
    }
  }
}

import Foundation

@testable import HarnessMonitorKit

/// Manual clock used by Monitor supervisor tests to step virtual time without relying on wall
/// clock sleeps. Maintains a pre-credit budget so `advance(by:)` calls that arrive before
/// `sleep(for:)` is registered still satisfy the pending sleep immediately, avoiding the race
/// where the tick loop hasn't yet called `sleep` when the test advances time.
final class TestClock: @unchecked Sendable, SupervisorClock {
  private struct Sleeper {
    let id: UUID
    let deadline: TimeInterval
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var nowValue: Date
  private var budget: TimeInterval = 0
  private var sleepers: [Sleeper] = []

  init(now: Date = .fixed) {
    self.nowValue = now
  }

  func now() -> Date {
    lock.withLock { nowValue }
  }

  /// Suspends the caller until `advance(by:)` has accumulated enough budget to cover `duration`.
  /// If the budget already covers the duration (pre-credit from a prior `advance` call),
  /// the method returns immediately without suspending.
  func sleep(for duration: Duration) async throws {
    let seconds = duration.inSeconds
    if Task.isCancelled {
      throw CancellationError()
    }
    let shouldReturnImmediately = lock.withLock { () -> Bool in
      if budget >= seconds {
        budget -= seconds
        nowValue = nowValue.addingTimeInterval(seconds)
        return true
      }
      return false
    }
    if shouldReturnImmediately { return }
    let sleeperID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let shouldCancelImmediately = lock.withLock { () -> Bool in
          if Task.isCancelled {
            return true
          }
          sleepers.append(
            Sleeper(
              id: sleeperID,
              deadline: seconds,
              continuation: continuation
            )
          )
          return false
        }
        if shouldCancelImmediately {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
        guard let index = self.sleepers.firstIndex(where: { $0.id == sleeperID }) else {
          return nil
        }
        return self.sleepers.remove(at: index).continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  /// Adds `duration` to the virtual-time budget and advances `now`. Any registered sleepers
  /// whose required duration is now covered are resumed immediately. Excess budget carries
  /// forward for the next `sleep(for:)` call, ensuring races between `advance` and `sleep`
  /// are handled correctly regardless of ordering.
  func advance(by duration: Duration) async {
    let resumed = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
      budget += duration.inSeconds
      nowValue = nowValue.addingTimeInterval(duration.inSeconds)
      var remaining: [Sleeper] = []
      var toResume: [CheckedContinuation<Void, Error>] = []
      for sleeper in sleepers {
        if budget >= sleeper.deadline {
          budget -= sleeper.deadline
          toResume.append(sleeper.continuation)
        } else {
          remaining.append(sleeper)
        }
      }
      sleepers = remaining
      return toResume
    }
    for continuation in resumed {
      continuation.resume()
    }
    await Task.yield()
  }
}

extension Duration {
  /// Converts this `Duration` to a seconds value that matches `TimeInterval` precision. The
  /// attoseconds component captures sub-second granularity so tests expressed as
  /// `.milliseconds(…)` round-trip cleanly.
  fileprivate var inSeconds: TimeInterval {
    let components = self.components
    let seconds = TimeInterval(components.seconds)
    let attoFraction = TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000.0
    return seconds + attoFraction
  }
}

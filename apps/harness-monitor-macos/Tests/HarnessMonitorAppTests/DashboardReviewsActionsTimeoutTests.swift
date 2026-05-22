import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies timeout racer", .serialized)
struct DashboardDependenciesActionsTimeoutTests {
  @Test("Race throws fetchTimedOut when the operation never returns")
  func raceTimesOutWhenOperationHangs() async throws {
    let waiter = ActionHangWaiter()

    let started = ContinuousClock.now
    var captured: (any Error)?
    do {
      _ = try await DashboardDependenciesTimeoutRacer.race(timeoutSeconds: 0.15) {
        try await waiter.waitForever()
      }
      Issue.record("expected fetchTimedOut, race returned successfully")
    } catch {
      captured = error
    }
    let elapsed = started.duration(to: ContinuousClock.now)

    #expect(captured as? DashboardDependenciesSchedulerError == .fetchTimedOut)
    #expect(elapsed < .seconds(2))

    waiter.release()
  }

  @Test("Race returns the operation result when it completes before the deadline")
  func raceReturnsOperationResultWhenFastEnough() async throws {
    let result = try await DashboardDependenciesTimeoutRacer.race(timeoutSeconds: 5) {
      "completed"
    }
    #expect(result == "completed")
  }

  @Test("Race rethrows the operation's own error without converting it to a timeout")
  func raceRethrowsOperationErrors() async throws {
    var captured: (any Error)?
    do {
      _ = try await DashboardDependenciesTimeoutRacer.race(timeoutSeconds: 5) {
        throw RaceTestError.operationFailed
      }
      Issue.record("expected operationFailed, race returned successfully")
    } catch {
      captured = error
    }
    #expect(captured as? RaceTestError == .operationFailed)
  }
}

private enum RaceTestError: Error, Equatable {
  case operationFailed
}

private final class ActionHangWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func waitForever() async throws -> Int {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
        return
      }
      continuations.append(continuation)
      lock.unlock()
    }
    return 0
  }

  func release() {
    lock.lock()
    released = true
    let pending = continuations
    continuations.removeAll()
    lock.unlock()
    for continuation in pending {
      continuation.resume()
    }
  }
}

import Foundation
import HarnessMonitorKit

/// Races an async operation against a timeout. Resolves to the operation's
/// result when it returns first; throws `DashboardReviewsSchedulerError`
/// `.fetchTimedOut` when the timeout fires first.
///
/// Used by the review scheduler, refresh, and per-PR action paths so a
/// hung daemon response (the wake-from-sleep zombie WS case) cannot leave a
/// UI affordance spinning forever. The WebSocket transport ships its own
/// 120s safety net; this racer adds a tighter ceiling for user-initiated
/// surfaces where waiting two minutes for "no response" would be a poor UX.
enum DashboardReviewsTimeoutRacer {
  /// Default timeout for catalog queries triggered by the scheduler.
  static let defaultQueryTimeoutSeconds: TimeInterval = 60
  /// Default timeout for refreshes triggered by user-visible row actions.
  static let defaultRefreshTimeoutSeconds: TimeInterval = 60
  /// Default timeout for mutations (approve/merge/label/auto/fixCI/cache).
  static let defaultMutationTimeoutSeconds: TimeInterval = 60

  static func race<T: Sendable>(
    timeoutSeconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    let outcome = AsyncStream<Outcome<T>>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let workTask = Task.detached(priority: .userInitiated) {
      do {
        let value = try await operation()
        outcome.continuation.yield(.success(value))
      } catch {
        outcome.continuation.yield(.failure(error))
      }
    }
    let timeoutTask = Task.detached {
      do {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        outcome.continuation.yield(
          .failure(DashboardReviewsSchedulerError.fetchTimedOut)
        )
      } catch {
        // sleep cancelled before timeout; the work task won the race
      }
    }
    defer {
      workTask.cancel()
      timeoutTask.cancel()
      outcome.continuation.finish()
    }
    var iterator = outcome.stream.makeAsyncIterator()
    guard let first = await iterator.next() else {
      throw DashboardReviewsSchedulerError.fetchTimedOut
    }
    switch first {
    case .success(let value): return value
    case .failure(let error): throw error
    }
  }

  private enum Outcome<T: Sendable>: Sendable {
    case success(T)
    case failure(any Error)
  }
}

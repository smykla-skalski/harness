import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Dashboard dependencies scheduler timeout + race")
struct DashboardDependenciesSchedulerTimeoutTests {
  @Test("fetch that never returns clears in-flight after the configured timeout")
  func neverReturningFetchTimesOut() async throws {
    let stub = HangingStub()
    let scheduler = DashboardDependenciesScheduler()
    scheduler.fetchTimeoutSeconds = 0.2

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 3_600
    prefs.maxConcurrentRepositoryFetches = 1

    scheduler.start(
      repositories: ["acme/api"],
      preferences: prefs,
      client: stub,
      onMerge: { _, _ in }
    )

    try await waitUntilInFlightContains(scheduler: scheduler, repo: "acme/api")
    #expect(scheduler.repositoriesInFlight == ["acme/api"])

    try await waitUntilInFlightCleared(scheduler: scheduler)
    #expect(scheduler.repositoriesInFlight.isEmpty)
    #expect(scheduler.states["acme/api"]?.lastErrorMessage != nil)
    scheduler.stop()
    stub.release()
  }

  @Test("stop+start during a hung fetch doesn't let the stale task corrupt new state")
  func stopRestartDuringHungFetchIsRaceSafe() async throws {
    let stub = HangingStub()
    let scheduler = DashboardDependenciesScheduler()
    scheduler.fetchTimeoutSeconds = 0.2

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 3_600
    prefs.maxConcurrentRepositoryFetches = 1

    scheduler.start(
      repositories: ["acme/api"],
      preferences: prefs,
      client: stub,
      onMerge: { _, _ in }
    )
    try await waitUntilInFlightContains(scheduler: scheduler, repo: "acme/api")

    // Restart while the first fetch is still hung. The new fetch's timer
    // will tick from this point; the stale T1 must not later remove the
    // new T2's marker when its own timeout finally fires.
    scheduler.stop()
    #expect(scheduler.repositoriesInFlight.isEmpty)
    scheduler.start(
      repositories: ["acme/api"],
      preferences: prefs,
      client: stub,
      forceRefreshAll: true,
      onMerge: { _, _ in }
    )
    try await waitUntilInFlightContains(scheduler: scheduler, repo: "acme/api")

    // Wait long enough for T1's timeout to have fired had it not been
    // generation-fenced; the new fetch (T2) must still own the in-flight
    // marker until its own timeout window elapses.
    try await Task.sleep(for: .milliseconds(50))
    #expect(scheduler.repositoriesInFlight == ["acme/api"])

    scheduler.stop()
    stub.release()
  }

  @Test("timeout error message is human-readable")
  func timeoutErrorHasUserFacingDescription() {
    let error = DashboardDependenciesSchedulerError.fetchTimedOut
    #expect(error.errorDescription?.isEmpty == false)
    #expect(error.errorDescription?.lowercased().contains("timed out") == true)
  }

  // MARK: - Helpers

  private func waitUntilInFlightContains(
    scheduler: DashboardDependenciesScheduler,
    repo: String
  ) async throws {
    for _ in 0..<200 where !scheduler.repositoriesInFlight.contains(repo) {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func waitUntilInFlightCleared(
    scheduler: DashboardDependenciesScheduler
  ) async throws {
    for _ in 0..<200 where !scheduler.repositoriesInFlight.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

/// A client stub whose `queryDependencyUpdates` never completes until
/// `release()` is called. Models the wake-from-sleep zombie connection: the
/// WebSocket RPC continuation never resumes, so the awaiting Task hangs.
@MainActor
private final class HangingStub:
  HarnessMonitorDependenciesClientProtocol, @unchecked Sendable
{
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func release() {
    lock.lock()
    let pending = continuations
    continuations.removeAll()
    lock.unlock()
    for continuation in pending {
      continuation.resume()
    }
  }

  func queryDependencyUpdates(
    request _: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      continuations.append(continuation)
      lock.unlock()
    }
    return DependencyUpdatesQueryResponse(
      fetchedAt: "2026-05-22T00:00:00Z",
      fromCache: false,
      summary: DependencyUpdatesSummary(items: []),
      items: []
    )
  }
}

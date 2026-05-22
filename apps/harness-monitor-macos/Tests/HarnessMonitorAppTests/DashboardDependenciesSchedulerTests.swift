import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Dashboard dependencies scheduler")
struct DashboardDependenciesSchedulerTests {
  @Test("cold start enqueues every repository under the concurrency cap")
  func coldStartEnqueuesEveryRepo() async throws {
    let stub = SchedulerStub()
    stub.responses = [
      "acme/api": stubResponse(),
      "acme/web": stubResponse(),
      "acme/cli": stubResponse(),
    ]
    let scheduler = DashboardDependenciesScheduler()
    var merges: [String] = []

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 3_600
    prefs.maxConcurrentRepositoryFetches = 2

    scheduler.start(
      repositories: ["acme/api", "acme/web", "acme/cli"],
      preferences: prefs,
      client: stub,
      onMerge: { repo, _ in merges.append(repo) }
    )
    try await waitUntilSettled(stub: stub, scheduler: scheduler)
    #expect(Set(merges) == Set(["acme/api", "acme/web", "acme/cli"]))
    #expect(stub.maxObservedConcurrent <= 2)
    scheduler.stop()
  }

  @Test("force refresh single repository bumps it ahead of others")
  func forceRefreshJumpsQueue() async throws {
    let stub = SchedulerStub()
    stub.responses = [
      "acme/api": stubResponse(),
      "acme/web": stubResponse(),
    ]
    let scheduler = DashboardDependenciesScheduler()
    var merges: [String] = []

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 60
    prefs.maxConcurrentRepositoryFetches = 1

    scheduler.start(
      repositories: ["acme/api", "acme/web"],
      preferences: prefs,
      client: stub,
      onMerge: { repo, _ in merges.append(repo) }
    )
    try await waitUntilSettled(stub: stub, scheduler: scheduler)

    scheduler.forceRefresh(repository: "acme/web")
    let baseline = stub.callCount(for: "acme/web")
    try await waitUntilFetchCount(stub: stub, repo: "acme/web", target: baseline + 1)
    scheduler.stop()
  }

  @Test("retry dispatches a fresh repository immediately")
  func retryDispatchesFreshRepositoryImmediately() async throws {
    let stub = SchedulerStub()
    stub.responses = ["acme/api": stubResponse()]
    let scheduler = DashboardDependenciesScheduler()

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 3_600
    prefs.maxConcurrentRepositoryFetches = 1

    scheduler.start(
      repositories: ["acme/api"],
      preferences: prefs,
      client: stub,
      initialLastSyncedAt: ["acme/api": Date()],
      onMerge: { _, _ in }
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(stub.totalCalls() == 0)

    await scheduler.retry(repository: "acme/api")
    try await waitUntilFetchCount(stub: stub, repo: "acme/api", target: 1)
    #expect(scheduler.states["acme/api"]?.lastErrorMessage == nil)
    scheduler.stop()
  }

  @Test("stop cancels in-flight work and clears the in-flight set")
  func stopCancelsAndClears() async throws {
    let stub = SchedulerStub()
    stub.responses = ["acme/api": stubResponse()]
    stub.delaySeconds = 0.5
    let scheduler = DashboardDependenciesScheduler()

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 30
    prefs.maxConcurrentRepositoryFetches = 1
    scheduler.start(
      repositories: ["acme/api"],
      preferences: prefs,
      client: stub,
      onMerge: { _, _ in }
    )
    try await Task.sleep(for: .milliseconds(50))
    scheduler.stop()
    #expect(scheduler.repositoriesInFlight.isEmpty)
  }

  @Test("initialLastSyncedAt hydrates state so relaunch resumes oldest-first")
  func initialLastSyncedAtSeedsRelaunchOrdering() async throws {
    let stub = SchedulerStub()
    stub.responses = [
      "acme/api": stubResponse(),
      "acme/web": stubResponse(),
    ]
    let scheduler = DashboardDependenciesScheduler()

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 3_600
    prefs.maxConcurrentRepositoryFetches = 1

    let older = Date(timeIntervalSinceNow: -7_200)
    let newer = Date(timeIntervalSinceNow: -300)

    scheduler.start(
      repositories: ["acme/api", "acme/web"],
      preferences: prefs,
      client: stub,
      initialLastSyncedAt: ["acme/api": newer, "acme/web": older],
      onMerge: { _, _ in }
    )
    try await waitUntilFetchCount(stub: stub, repo: "acme/web", target: 1)
    try await Task.sleep(for: .milliseconds(100))

    #expect(stub.callCount(for: "acme/web") == 1)
    #expect(stub.callCount(for: "acme/api") == 0)
    #expect(scheduler.states["acme/api"]?.lastSyncedAt == newer)
    scheduler.stop()
  }

  @Test("restart with fresh repository list drops orphaned state entries")
  func restartTrimsStates() async throws {
    let stub = SchedulerStub()
    stub.responses = [
      "acme/api": stubResponse(),
      "acme/web": stubResponse(),
    ]
    let scheduler = DashboardDependenciesScheduler()

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 3_600
    prefs.maxConcurrentRepositoryFetches = 4
    scheduler.start(
      repositories: ["acme/api", "acme/web"],
      preferences: prefs,
      client: stub,
      onMerge: { _, _ in }
    )
    try await waitUntilSettled(stub: stub, scheduler: scheduler)

    scheduler.start(
      repositories: ["acme/api"],
      preferences: prefs,
      client: stub,
      onMerge: { _, _ in }
    )
    try await Task.sleep(for: .milliseconds(50))
    #expect(scheduler.states.keys.sorted() == ["acme/api"])
    scheduler.stop()
  }

  @Test("forced restart refreshes newly hydrated repositories")
  func forcedRestartRefreshesNewlyHydratedRepositories() async throws {
    let stub = SchedulerStub()
    stub.responses = [
      "acme/api": stubResponse(),
      "acme/web": stubResponse(),
    ]
    let scheduler = DashboardDependenciesScheduler()

    var prefs = DashboardDependenciesPreferences()
    prefs.perRepositoryIntervalSeconds = 3_600
    prefs.maxConcurrentRepositoryFetches = 2
    let fresh = Date()

    scheduler.start(
      repositories: ["acme/api"],
      preferences: prefs,
      client: stub,
      initialLastSyncedAt: ["acme/api": fresh],
      onMerge: { _, _ in }
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(stub.totalCalls() == 0)

    scheduler.start(
      repositories: ["acme/api", "acme/web"],
      preferences: prefs,
      client: stub,
      initialLastSyncedAt: ["acme/api": fresh, "acme/web": fresh],
      forceRefreshAll: true,
      onMerge: { _, _ in }
    )

    try await waitUntilFetchCount(stub: stub, repo: "acme/api", target: 1)
    try await waitUntilFetchCount(stub: stub, repo: "acme/web", target: 1)
    #expect(stub.callCount(for: "acme/api") == 1)
    #expect(stub.callCount(for: "acme/web") == 1)
    scheduler.stop()
  }

  // MARK: - Helpers

  private func stubResponse() -> DependencyUpdatesQueryResponse {
    DependencyUpdatesQueryResponse(
      fetchedAt: "2026-05-21T00:00:00Z",
      fromCache: false,
      summary: DependencyUpdatesSummary(items: []),
      items: []
    )
  }

  private func waitUntilSettled(
    stub: SchedulerStub,
    scheduler: DashboardDependenciesScheduler
  ) async throws {
    for _ in 0..<60
    where !scheduler.repositoriesInFlight.isEmpty
      || stub.totalCalls() < stub.responseCount
    {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func waitUntilFetchCount(
    stub: SchedulerStub,
    repo: String,
    target: Int
  ) async throws {
    for _ in 0..<60 where stub.callCount(for: repo) < target {
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}

@MainActor
private final class SchedulerStub: HarnessMonitorDependenciesClientProtocol, @unchecked Sendable {
  private let lock = NSLock()
  var responses: [String: DependencyUpdatesQueryResponse] = [:]
  var delaySeconds: Double = 0
  private var fetchCounts: [String: Int] = [:]
  private var inFlightCount: Int = 0
  private var observedMaxConcurrent: Int = 0

  var maxObservedConcurrent: Int {
    lock.withLock { observedMaxConcurrent }
  }
  var responseCount: Int {
    lock.withLock { responses.count }
  }

  func callCount(for repository: String) -> Int {
    lock.withLock { fetchCounts[repository] ?? 0 }
  }

  func totalCalls() -> Int {
    lock.withLock { fetchCounts.values.reduce(0, +) }
  }

  func queryDependencyUpdates(
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    let repository = request.repositories.first ?? ""
    let response: DependencyUpdatesQueryResponse = lock.withLock {
      fetchCounts[repository, default: 0] += 1
      inFlightCount += 1
      observedMaxConcurrent = max(observedMaxConcurrent, inFlightCount)
      return responses[repository]
        ?? DependencyUpdatesQueryResponse(
          fetchedAt: "2026-05-21T00:00:00Z",
          fromCache: false,
          summary: DependencyUpdatesSummary(items: []),
          items: []
        )
    }
    if delaySeconds > 0 {
      try await Task.sleep(for: .seconds(delaySeconds))
    }
    lock.withLock {
      inFlightCount -= 1
    }
    return response
  }
}

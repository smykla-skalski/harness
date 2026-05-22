import Foundation
import HarnessMonitorKit
import Observation

/// Drives per-repository dependency syncs, spreading them over time so a
/// single tick never fans out to every repository at once.
///
/// The scheduler holds a `RepoSyncState` per repository and runs a tick loop
/// that wakes at `perRepoInterval / max(repositoryCount, 1)`. On each tick it
/// dispatches the stalest repositories — up to `maxConcurrent` in flight —
/// to the daemon's per-repo query endpoint and forwards each response to the
/// `onMerge` callback so the route view can fold it into its snapshot.
@MainActor
@Observable
final class DashboardDependenciesScheduler {
  struct RepoSyncState: Equatable {
    var lastSyncedAt: Date?
    var lastErrorMessage: String?
    var forceRefreshRequested: Bool = false
  }

  /// Per-fetch upper bound. The daemon's WebSocket RPC has no resource timeout,
  /// so a sleep/wake or zombie TCP connection can leave a query awaiting
  /// forever. This bound guarantees `repositoriesInFlight` clears within a
  /// fixed window even if the response never arrives; the next tick can then
  /// retry.
  static let defaultFetchTimeoutSeconds: TimeInterval = 60

  /// Repositories currently being fetched. SwiftUI reads this to render
  /// per-section progress indicators.
  private(set) var repositoriesInFlight: Set<String> = []

  /// Per-repository sync state keyed by `owner/name`.
  private(set) var states: [String: RepoSyncState] = [:]

  @ObservationIgnored private var tickTask: Task<Void, Never>?
  @ObservationIgnored private var fetchTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var perRepoInterval: TimeInterval = 300
  @ObservationIgnored private var maxConcurrent: Int = 2
  @ObservationIgnored private var repositories: [String] = []
  @ObservationIgnored private var client: (any HarnessMonitorDependenciesClientProtocol)?
  @ObservationIgnored private var preferences = DashboardDependenciesResolvedPreferences(
    preferences: .init()
  )
  @ObservationIgnored private var onMerge:
    (@MainActor (String, DependencyUpdatesQueryResponse) -> Void)?

  /// Bumped on every `stop()` (which `start()` calls first). Tasks capture the
  /// generation at launch and skip cleanup if the value has moved on — this
  /// prevents a stale task whose timeout fires after a `start()` restart from
  /// removing the new task's `repositoriesInFlight` marker.
  @ObservationIgnored private var fetchGeneration: UInt = 0

  /// Per-fetch timeout. Tests override this to make race scenarios feasible.
  @ObservationIgnored var fetchTimeoutSeconds: TimeInterval = defaultFetchTimeoutSeconds

  /// Begin or restart the scheduler with a fresh set of inputs.
  ///
  /// Cancels any in-flight fetches and resets the tick loop. Repositories
  /// missing from `repositories` are dropped from `states`; new ones are
  /// seeded with `lastSyncedAt` from `initialLastSyncedAt` (or `nil` when
  /// absent) so a relaunch resumes oldest-first instead of treating every
  /// repository as cold.
  func start(
    repositories: [String],
    preferences: DashboardDependenciesPreferences,
    client: any HarnessMonitorDependenciesClientProtocol,
    initialLastSyncedAt: [String: Date] = [:],
    forceRefreshAll: Bool = false,
    onMerge: @escaping @MainActor (String, DependencyUpdatesQueryResponse) -> Void
  ) {
    start(
      repositories: repositories,
      preferences: DashboardDependenciesResolvedPreferences(preferences: preferences),
      client: client,
      initialLastSyncedAt: initialLastSyncedAt,
      forceRefreshAll: forceRefreshAll,
      onMerge: onMerge
    )
  }

  func start(
    repositories: [String],
    preferences: DashboardDependenciesResolvedPreferences,
    client: any HarnessMonitorDependenciesClientProtocol,
    initialLastSyncedAt: [String: Date] = [:],
    forceRefreshAll: Bool = false,
    onMerge: @escaping @MainActor (String, DependencyUpdatesQueryResponse) -> Void
  ) {
    stop()
    self.repositories = repositories
    self.preferences = preferences
    self.perRepoInterval = max(
      TimeInterval(preferences.preferences.perRepositoryIntervalSeconds), 1)
    self.maxConcurrent = max(preferences.preferences.maxConcurrentRepositoryFetches, 1)
    self.client = client
    self.onMerge = onMerge

    for repository in repositories where states[repository] == nil {
      var state = RepoSyncState()
      state.lastSyncedAt = initialLastSyncedAt[repository]
      states[repository] = state
    }
    for repository in repositories {
      if states[repository]?.lastSyncedAt == nil,
        let hydrated = initialLastSyncedAt[repository]
      {
        states[repository]?.lastSyncedAt = hydrated
      }
      if forceRefreshAll {
        states[repository]?.forceRefreshRequested = true
      }
    }
    for key in Array(states.keys) where !repositories.contains(key) {
      states.removeValue(forKey: key)
    }

    guard !repositories.isEmpty else { return }
    tickTask = Task { [weak self] in
      await self?.runTickLoop()
    }
  }

  /// Cancel the tick loop and all in-flight fetch tasks. Safe to call
  /// repeatedly. `states` is preserved so a subsequent `start` can resume
  /// from prior `lastSyncedAt` markers within the same session.
  func stop() {
    fetchGeneration &+= 1
    tickTask?.cancel()
    tickTask = nil
    for (_, task) in fetchTasks {
      task.cancel()
    }
    fetchTasks.removeAll()
    repositoriesInFlight.removeAll()
  }

  /// Mark every tracked repository for refresh on the next tick.
  func forceRefreshAll() {
    for key in states.keys {
      states[key]?.forceRefreshRequested = true
    }
  }

  /// Mark a single repository for refresh on the next tick. No-op when the
  /// repository is not tracked.
  func forceRefresh(repository: String) {
    states[repository]?.forceRefreshRequested = true
  }

  private func runTickLoop() async {
    await dispatchPending()
    while !Task.isCancelled {
      let interval = perRepoInterval / Double(max(repositories.count, 1))
      do {
        try await Task.sleep(for: .seconds(max(interval, 0.1)))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await dispatchPending()
    }
  }

  private func dispatchPending() async {
    guard repositoriesInFlight.count < maxConcurrent else { return }
    let now = Date()
    let candidates =
      repositories
      .filter { !repositoriesInFlight.contains($0) }
      .sorted { lhs, rhs in
        let lhsForce = states[lhs]?.forceRefreshRequested ?? false
        let rhsForce = states[rhs]?.forceRefreshRequested ?? false
        if lhsForce != rhsForce { return lhsForce && !rhsForce }
        let lhsDate = states[lhs]?.lastSyncedAt ?? .distantPast
        let rhsDate = states[rhs]?.lastSyncedAt ?? .distantPast
        return lhsDate < rhsDate
      }

    for repository in candidates {
      guard repositoriesInFlight.count < maxConcurrent else { break }
      guard isStale(repository: repository, now: now) else { continue }
      launchFetch(for: repository)
    }
  }

  private func isStale(repository: String, now: Date) -> Bool {
    guard let state = states[repository] else { return true }
    if state.forceRefreshRequested { return true }
    guard let lastSyncedAt = state.lastSyncedAt else { return true }
    return now.timeIntervalSince(lastSyncedAt) >= perRepoInterval
  }

  private func launchFetch(for repository: String) {
    guard let client, let onMerge else { return }
    repositoriesInFlight.insert(repository)
    states[repository]?.forceRefreshRequested = false
    let request = preferences.perRepositoryQueryRequest(
      for: repository,
      forceRefresh: true
    )
    let generation = fetchGeneration
    let timeout = fetchTimeoutSeconds
    let task = Task { @MainActor [weak self] in
      do {
        let response = try await DashboardDependenciesTimeoutRacer.race(
          timeoutSeconds: timeout
        ) {
          try await DashboardDependenciesRemoteLoader.query(
            client: client,
            request: request
          )
        }
        guard let self, self.fetchGeneration == generation else { return }
        self.states[repository]?.lastSyncedAt = Date()
        self.states[repository]?.lastErrorMessage = nil
        onMerge(repository, response)
      } catch is CancellationError {
        return
      } catch let error as DashboardDependenciesSchedulerError {
        guard let self, self.fetchGeneration == generation else { return }
        self.states[repository]?.lastErrorMessage = error.localizedDescription
        HarnessMonitorLogger.api.warning(
          """
          Per-repository dependency fetch timed out: \
          repository=\(repository, privacy: .public) \
          timeout=\(timeout, privacy: .public)s
          """
        )
      } catch {
        guard let self, self.fetchGeneration == generation else { return }
        self.states[repository]?.lastErrorMessage = error.localizedDescription
      }
      guard let self, self.fetchGeneration == generation else { return }
      self.repositoriesInFlight.remove(repository)
      self.fetchTasks.removeValue(forKey: repository)
      if self.states[repository]?.lastErrorMessage == nil {
        await self.dispatchPending()
      }
    }
    fetchTasks[repository] = task
  }

  // Per-fetch timeout-racing moved to `DashboardDependenciesTimeoutRacer.race`
  // so refresh and per-PR action paths can reuse the same wake-zombie guard.
}

/// Errors emitted by `DashboardDependenciesScheduler`.
enum DashboardDependenciesSchedulerError: LocalizedError, Equatable {
  /// The per-repository fetch did not complete within the configured timeout.
  /// In practice this means the daemon's WebSocket response never arrived —
  /// most commonly because the underlying TCP connection went zombie during
  /// sleep/wake.
  case fetchTimedOut

  var errorDescription: String? {
    switch self {
    case .fetchTimedOut:
      return "Dependency refresh timed out. The daemon will be retried on the next tick."
    }
  }
}

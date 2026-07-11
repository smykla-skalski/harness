import Foundation
import HarnessMonitorKit
import Observation

private struct DashboardReviewsDispatchCandidate {
  let repository: String
  let isForced: Bool
  let lastSyncedAt: Date
}

/// Drives per-repository review syncs, spreading them over time so a
/// single tick never fans out to every repository at once.
///
/// The scheduler holds a `RepoSyncState` per repository and runs a tick loop
/// that wakes at `perRepoInterval / max(repositoryCount, 1)`. On each tick it
/// dispatches the stalest repositories — up to `maxConcurrent` in flight —
/// to the daemon's per-repo query endpoint and forwards each response to the
/// `onMerge` callback so the route view can fold it into its snapshot.
@MainActor
@Observable
final class DashboardReviewsScheduler {
  struct RepoSyncState: Equatable {
    var lastSyncedAt: Date?
    var lastErrorMessage: String?
    var forceRefreshRequested: Bool = false
    fileprivate var forceRefreshGeneration: UInt64 = 0
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
  @ObservationIgnored private var client: (any HarnessMonitorReviewsClientProtocol)?
  @ObservationIgnored private var preferences = DashboardReviewsResolvedPreferences(
    preferences: .init()
  )
  @ObservationIgnored private var onMerge: (@MainActor (String, ReviewsQueryResponse) -> Void)?

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
    preferences: DashboardReviewsPreferences,
    client: any HarnessMonitorReviewsClientProtocol,
    initialLastSyncedAt: [String: Date] = [:],
    forceRefreshAll: Bool = false,
    onMerge: @escaping @MainActor (String, ReviewsQueryResponse) -> Void
  ) {
    start(
      repositories: repositories,
      preferences: DashboardReviewsResolvedPreferences(preferences: preferences),
      client: client,
      initialLastSyncedAt: initialLastSyncedAt,
      forceRefreshAll: forceRefreshAll,
      onMerge: onMerge
    )
  }

  func start(
    repositories: [String],
    preferences: DashboardReviewsResolvedPreferences,
    client: any HarnessMonitorReviewsClientProtocol,
    initialLastSyncedAt: [String: Date] = [:],
    forceRefreshAll: Bool = false,
    onMerge: @escaping @MainActor (String, ReviewsQueryResponse) -> Void
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
        requestForceRefresh(repository: repository)
      }
    }
    for key in Array(states.keys) where !repositories.contains(key) {
      states.removeValue(forKey: key)
    }

    guard !repositories.isEmpty else { return }
    dispatchPending()
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
      requestForceRefresh(repository: key)
    }
  }

  /// Mark a single repository for refresh on the next tick. No-op when the
  /// repository is not tracked.
  func forceRefresh(repository: String) {
    guard let tracked = trackedRepository(matching: repository) else { return }
    requestForceRefresh(repository: tracked)
  }

  /// Mark a repository for refresh and immediately try to dispatch it.
  func retry(repository: String) async {
    guard let tracked = trackedRepository(matching: repository) else { return }
    forceRefresh(repository: tracked)
    dispatchPending()
  }

  /// Ensure a repository is part of the scheduler's tracked set. Returns the
  /// canonical tracked identifier the caller should use for follow-up actions.
  @discardableResult
  func ensureTracked(
    repository: String,
    lastSyncedAt: Date? = nil
  ) -> String {
    let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return repository }

    if let tracked = trackedRepository(matching: trimmed) {
      if states[tracked] == nil {
        var state = RepoSyncState()
        state.lastSyncedAt = lastSyncedAt
        states[tracked] = state
        dispatchPending()
      } else if states[tracked]?.lastSyncedAt == nil, let lastSyncedAt {
        states[tracked]?.lastSyncedAt = lastSyncedAt
      }
      return tracked
    }

    repositories.append(trimmed)
    var state = RepoSyncState()
    state.lastSyncedAt = lastSyncedAt
    states[trimmed] = state
    dispatchPending()
    return trimmed
  }

  func syncState(for repository: String) -> RepoSyncState? {
    guard let tracked = trackedRepository(matching: repository) else { return nil }
    return states[tracked]
  }

  func isRepositoryInFlight(_ repository: String) -> Bool {
    guard let tracked = trackedRepository(matching: repository) else { return false }
    return repositoriesInFlight.contains(tracked)
  }

  private func runTickLoop() async {
    while !Task.isCancelled {
      let interval = perRepoInterval / Double(max(repositories.count, 1))
      do {
        try await Task.sleep(for: .seconds(max(interval, 0.1)))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      dispatchPending()
    }
  }

  private func dispatchPending() {
    guard repositoriesInFlight.count < maxConcurrent else { return }
    let now = Date()
    let candidates = dispatchCandidates(
      now: now,
      limit: maxConcurrent - repositoriesInFlight.count
    )
    for candidate in candidates {
      launchFetch(for: candidate.repository, forceRefresh: candidate.isForced)
    }
  }

  private func dispatchCandidates(
    now: Date,
    limit: Int
  ) -> [DashboardReviewsDispatchCandidate] {
    guard limit > 0 else { return [] }

    var candidates: [DashboardReviewsDispatchCandidate] = []
    candidates.reserveCapacity(limit + 1)
    for repository in repositories {
      guard !repositoriesInFlight.contains(repository) else { continue }
      guard isStale(repository: repository, now: now) else { continue }
      candidates.insertSortedByDispatchPriority(dispatchCandidate(for: repository))
      if candidates.count > limit {
        candidates.removeLast()
      }
    }
    return candidates
  }

  private func dispatchCandidate(for repository: String) -> DashboardReviewsDispatchCandidate {
    let state = states[repository]
    return DashboardReviewsDispatchCandidate(
      repository: repository,
      isForced: state?.forceRefreshRequested ?? false,
      lastSyncedAt: state?.lastSyncedAt ?? .distantPast
    )
  }

  private func isStale(repository: String, now: Date) -> Bool {
    guard let state = states[repository] else { return true }
    if state.forceRefreshRequested { return true }
    guard let lastSyncedAt = state.lastSyncedAt else { return true }
    return now.timeIntervalSince(lastSyncedAt) >= perRepoInterval
  }

  private func launchFetch(for repository: String, forceRefresh: Bool) {
    guard let client, let onMerge else { return }
    repositoriesInFlight.insert(repository)
    let forceRefreshGeneration =
      forceRefresh ? states[repository]?.forceRefreshGeneration : nil
    let request = preferences.perRepositoryQueryRequest(
      for: repository,
      forceRefresh: forceRefresh
    )
    let generation = fetchGeneration
    let timeout = fetchTimeoutSeconds
    let task = Task { @MainActor [weak self] in
      do {
        let response = try await DashboardReviewsTimeoutRacer.race(
          timeoutSeconds: timeout
        ) {
          try await DashboardReviewsRemoteLoader.query(
            client: client,
            request: request
          )
        }
        guard let self, self.fetchGeneration == generation else { return }
        if let forceRefreshGeneration,
          self.states[repository]?.forceRefreshGeneration == forceRefreshGeneration
        {
          self.states[repository]?.forceRefreshRequested = false
        }
        self.states[repository]?.lastSyncedAt = Date()
        self.states[repository]?.lastErrorMessage = nil
        onMerge(repository, response)
      } catch is CancellationError {
        return
      } catch let error as DashboardReviewsSchedulerError {
        guard let self, self.fetchGeneration == generation else { return }
        self.states[repository]?.lastErrorMessage = error.localizedDescription
        HarnessMonitorLogger.api.warning(
          """
          Per-repository review fetch timed out: \
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
        self.dispatchPending()
      }
    }
    fetchTasks[repository] = task
  }

  private func requestForceRefresh(repository: String) {
    states[repository]?.forceRefreshGeneration &+= 1
    states[repository]?.forceRefreshRequested = true
  }

  private func trackedRepository(matching repository: String) -> String? {
    let repositoryKey = dashboardReviewsRepositoryTrackingKey(repository)
    guard !repositoryKey.isEmpty else { return nil }
    if states[repository] != nil {
      return repository
    }
    if let tracked = states.keys.first(where: {
      dashboardReviewsRepositoryTrackingKey($0) == repositoryKey
    }) {
      return tracked
    }
    if let tracked = repositories.first(where: {
      dashboardReviewsRepositoryTrackingKey($0) == repositoryKey
    }) {
      return tracked
    }
    if let tracked = repositoriesInFlight.first(where: {
      dashboardReviewsRepositoryTrackingKey($0) == repositoryKey
    }) {
      return tracked
    }
    return nil
  }

  // Per-fetch timeout-racing moved to `DashboardReviewsTimeoutRacer.race`
  // so refresh and per-PR action paths can reuse the same wake-zombie guard.
}

extension Array where Element == DashboardReviewsDispatchCandidate {
  fileprivate mutating func insertSortedByDispatchPriority(
    _ candidate: DashboardReviewsDispatchCandidate
  ) {
    let index =
      firstIndex { candidate.precedesForDispatch($0) }
      ?? endIndex
    insert(candidate, at: index)
  }
}

extension DashboardReviewsDispatchCandidate {
  fileprivate func precedesForDispatch(_ other: Self) -> Bool {
    if isForced != other.isForced {
      return isForced && !other.isForced
    }
    if lastSyncedAt != other.lastSyncedAt {
      return lastSyncedAt < other.lastSyncedAt
    }
    return false
  }
}

/// Errors emitted by `DashboardReviewsScheduler`.
enum DashboardReviewsSchedulerError: LocalizedError, Equatable {
  /// The per-repository fetch did not complete within the configured timeout.
  /// In practice this means the daemon's WebSocket response never arrived —
  /// most commonly because the underlying TCP connection went zombie during
  /// sleep/wake.
  case fetchTimedOut

  var errorDescription: String? {
    switch self {
    case .fetchTimedOut:
      return "Review refresh timed out. The daemon will be retried on the next tick."
    }
  }
}

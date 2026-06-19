import Foundation
import HarnessMonitorKit

@MainActor let reviewsRelativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .short
  return formatter
}()

enum DashboardReviewsRemoteLoader {
  static func query(
    client: any HarnessMonitorReviewsClientProtocol,
    request: ReviewsQueryRequest
  ) async throws -> ReviewsQueryResponse {
    let task = Task.detached(priority: .userInitiated) {
      try await client.queryReviews(request: request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static func refresh(
    client: any HarnessMonitorReviewsClientProtocol,
    request: ReviewsRefreshRequest
  ) async throws -> ReviewsRefreshResponse {
    let task = Task.detached(priority: .userInitiated) {
      try await client.refreshReviews(request: request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

struct DashboardReviewsReloadTaskKey: Hashable {
  let preferencesSignature: String
  let isConnected: Bool
}

/// Classify a `HarnessMonitorStore.ConnectionState` into a stable boolean for the
/// reviews reload task key. Only terminal "we have a live link" states are
/// considered connected; transient states like `.connecting` are folded into
/// `false` so that a flap `offline -> connecting -> online` produces a single
/// key flip (the offline -> online edge) instead of two reloads.
func isReviewsReloadConnected(_ state: HarnessMonitorStore.ConnectionState) -> Bool {
  switch state {
  case .online:
    return true
  case .idle, .connecting, .offline:
    return false
  }
}

/// Decision produced by `dashboardReviewsRouteChangeDecision`. The route view
/// owns the SwiftUI plumbing; this enum lets the policy be tested as a pure
/// transform from `(was the reviews route active?, did work survive the leave?,
/// new route)` to "what should happen next?".
enum DashboardReviewsRouteChangeDecision: Equatable {
  /// User left the reviews route. Mark it inactive and remember whether a
  /// resume-on-return reload is owed because in-flight refreshes were still
  /// running when they navigated away.
  case leave(armPendingResume: Bool)
  /// User came back to the reviews route. If `triggerReload` is true the
  /// caller must run a soft `reload(forceRefresh: false, backgroundRefresh:
  /// true)` so the user sees fresh data without a loading spinner.
  case returnToRoute(triggerReload: Bool)
  /// The new route equals the old route (e.g. the route picker re-emitted
  /// without actually changing). No state mutation needed.
  case noChange
}

/// Pure transform from "route picker changed" to the resume-on-leave
/// decision the view should apply. The route view delegates to this so the
/// pause-on-leave heuristic can be tested without a SwiftUI hosting context
/// or a daemon store.
///
/// Inputs:
/// - `newRoute`: the route the picker just selected.
/// - `wasOnReviews`: whether the previous selection was the reviews route.
/// - `hasInFlightWork`: whether any tracked refresh or mutation task may
///   still be running when the route is leaving.
/// - `hasPendingResume`: whether a previous leave already armed a
///   resume-on-return reload.
func dashboardReviewsRouteChangeDecision(
  newRoute: DashboardWindowRoute,
  wasOnReviews: Bool,
  hasInFlightWork: Bool,
  hasPendingResume: Bool
) -> DashboardReviewsRouteChangeDecision {
  let goingToReviews = newRoute == .reviews
  if goingToReviews {
    guard !wasOnReviews else { return .noChange }
    return .returnToRoute(triggerReload: hasPendingResume)
  }
  guard wasOnReviews else { return .noChange }
  return .leave(armPendingResume: hasInFlightWork)
}

struct DashboardReviewsQueryRequestParts {
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let cacheMaxAgeSeconds: UInt64
  let forceRefresh: Bool
  let backportDetectionEnabled: Bool
  let backportPatterns: [String]
}

struct DashboardReviewsResolvedPreferences: Equatable {
  let preferences: DashboardReviewsPreferences
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let cacheHash: String

  init(storedValue: String) {
    self.init(preferences: DashboardReviewsPreferences.decode(from: storedValue))
  }

  init(preferences: DashboardReviewsPreferences) {
    let normalized = preferences.normalized()
    self.preferences = normalized
    authors = normalized.normalizedAuthors
    organizations = normalized.normalizedOrganizations
    repositories = normalized.normalizedRepositories
    excludeRepositories = normalized.normalizedExcludeRepositories
    cacheHash = ReviewsCache.preferencesHash(
      for: Self.queryRequest(
        DashboardReviewsQueryRequestParts(
          authors: authors,
          organizations: organizations,
          repositories: repositories,
          excludeRepositories: excludeRepositories,
          cacheMaxAgeSeconds: normalized.cacheMaxAgeSeconds,
          forceRefresh: false,
          backportDetectionEnabled: normalized.backportDetectionEnabled,
          backportPatterns: normalized.normalizedBackportPatterns
        )
      )
    )
  }

  func queryRequest(forceRefresh: Bool) -> ReviewsQueryRequest {
    Self.queryRequest(
      DashboardReviewsQueryRequestParts(
        authors: authors,
        organizations: organizations,
        repositories: repositories,
        excludeRepositories: excludeRepositories,
        cacheMaxAgeSeconds: preferences.cacheMaxAgeSeconds,
        forceRefresh: forceRefresh,
        backportDetectionEnabled: preferences.backportDetectionEnabled,
        backportPatterns: preferences.normalizedBackportPatterns
      )
    )
  }

  func perRepositoryQueryRequest(
    for repository: String,
    forceRefresh: Bool
  ) -> ReviewsQueryRequest {
    Self.queryRequest(
      DashboardReviewsQueryRequestParts(
        authors: authors,
        organizations: [],
        repositories: [repository],
        excludeRepositories: excludeRepositories,
        cacheMaxAgeSeconds: preferences.cacheMaxAgeSeconds,
        forceRefresh: forceRefresh,
        backportDetectionEnabled: preferences.backportDetectionEnabled,
        backportPatterns: preferences.normalizedBackportPatterns
      )
    )
  }

  fileprivate static func queryRequest(_ parts: DashboardReviewsQueryRequestParts)
    -> ReviewsQueryRequest
  {
    ReviewsQueryRequest(
      authors: parts.authors,
      organizations: parts.organizations,
      repositories: parts.repositories,
      excludeRepositories: parts.excludeRepositories,
      forceRefresh: parts.forceRefresh,
      cacheMaxAgeSeconds: max(
        parts.cacheMaxAgeSeconds,
        DashboardReviewsPreferences.minimumPerRepositoryIntervalSeconds
      ),
      backportDetectionEnabled: parts.backportDetectionEnabled,
      backportPatterns: parts.backportPatterns
    )
  }
}

/// Formats the loading copy shown while the per-repo scheduler is fetching
/// reviews. When the scheduler is tracking repositories we surface
/// "Loading reviews… (X / Y repositories)" so the user can see progress on
/// cold launches with many repositories; otherwise we fall back to the bare
/// "Loading reviews…" copy.
func dashboardReviewsLoadingLabel(
  totalRepositories: Int,
  syncedRepositories: Int
) -> String {
  guard totalRepositories > 0 else { return "Loading reviews…" }
  let clamped = min(max(syncedRepositories, 0), totalRepositories)
  return "Loading reviews… (\(clamped) / \(totalRepositories) repositories)"
}

enum DashboardReviewsMissingClientState: Equatable {
  case ignore
  case loading
  case error(String)
}

func dashboardReviewsMissingClientState(
  backgroundRefresh: Bool,
  connectionState: HarnessMonitorStore.ConnectionState
) -> DashboardReviewsMissingClientState {
  guard !backgroundRefresh else {
    return .ignore
  }
  if connectionState == .connecting {
    return .loading
  }
  return .error(
    """
    Harness Monitor is starting up. The local sync engine isn't ready yet. \
    Retry in a moment or check Settings > Diagnostics.
    """
  )
}

func dashboardReviewsShouldForceSchedulerRefresh(
  explicitForceRefresh: Bool,
  cacheApplied: Bool,
  response: ReviewsQueryResponse
) -> Bool {
  explicitForceRefresh || (!cacheApplied && response.items.isEmpty && response.fetchedAt.isEmpty)
}

func dashboardReviewsRepositoryTrackingKey(_ repository: String) -> String {
  repository
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
}

func dashboardReviewsTrackedRepositories(
  resolvedRepositories: [String],
  visibleRepositories: [String],
  excludeRepositories: [String]
) -> [String] {
  let excludedKeys = Set(excludeRepositories.map(dashboardReviewsRepositoryTrackingKey))
  var seenKeys = Set<String>()
  var result: [String] = []
  result.reserveCapacity(resolvedRepositories.count + visibleRepositories.count)

  func append(_ repository: String) {
    let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = dashboardReviewsRepositoryTrackingKey(trimmed)
    guard !key.isEmpty, !excludedKeys.contains(key), seenKeys.insert(key).inserted else { return }
    result.append(trimmed)
  }

  resolvedRepositories.forEach(append)
  visibleRepositories.forEach(append)
  return result
}

func dashboardReviewsHydratedLastSyncedAt(
  repository: String,
  hydratedStates: [String: Date]
) -> Date? {
  if let exact = hydratedStates[repository] {
    return exact
  }
  let repositoryKey = dashboardReviewsRepositoryTrackingKey(repository)
  guard !repositoryKey.isEmpty else { return nil }
  return hydratedStates.first {
    dashboardReviewsRepositoryTrackingKey($0.key) == repositoryKey
  }?.value
}

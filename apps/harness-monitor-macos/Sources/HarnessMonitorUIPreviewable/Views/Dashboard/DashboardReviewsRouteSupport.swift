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

struct DashboardReviewsReloadTaskKey: Equatable {
  let preferencesSignature: String
  let connectionState: HarnessMonitorStore.ConnectionState
}

struct DashboardReviewsQueryRequestParts {
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let cacheMaxAgeSeconds: UInt64
  let forceRefresh: Bool
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
          forceRefresh: false
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
        forceRefresh: forceRefresh
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
        forceRefresh: forceRefresh
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
      )
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

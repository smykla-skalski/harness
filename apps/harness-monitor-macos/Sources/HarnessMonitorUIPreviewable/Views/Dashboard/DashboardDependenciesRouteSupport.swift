import Foundation
import HarnessMonitorKit

@MainActor let dependenciesRelativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .short
  return formatter
}()

enum DashboardDependenciesRemoteLoader {
  static func query(
    client: any HarnessMonitorDependenciesClientProtocol,
    request: DependencyUpdatesQueryRequest
  ) async throws -> DependencyUpdatesQueryResponse {
    let task = Task.detached(priority: .userInitiated) {
      try await client.queryDependencyUpdates(request: request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static func refresh(
    client: any HarnessMonitorDependenciesClientProtocol,
    request: DependencyUpdatesRefreshRequest
  ) async throws -> DependencyUpdatesRefreshResponse {
    let task = Task.detached(priority: .userInitiated) {
      try await client.refreshDependencyUpdates(request: request)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

struct DashboardDependenciesReloadTaskKey: Equatable {
  let preferencesSignature: String
  let connectionState: HarnessMonitorStore.ConnectionState
}

struct DashboardDependenciesQueryRequestParts {
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let cacheMaxAgeSeconds: UInt64
  let forceRefresh: Bool
}

struct DashboardDependenciesResolvedPreferences: Equatable {
  let preferences: DashboardDependenciesPreferences
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let cacheHash: String

  init(storedValue: String) {
    self.init(preferences: DashboardDependenciesPreferences.decode(from: storedValue))
  }

  init(preferences: DashboardDependenciesPreferences) {
    let normalized = preferences.normalized()
    self.preferences = normalized
    authors = normalized.normalizedAuthors
    organizations = normalized.normalizedOrganizations
    repositories = normalized.normalizedRepositories
    excludeRepositories = normalized.normalizedExcludeRepositories
    cacheHash = DependencyUpdatesCache.preferencesHash(
      for: Self.queryRequest(
        DashboardDependenciesQueryRequestParts(
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

  func queryRequest(forceRefresh: Bool) -> DependencyUpdatesQueryRequest {
    Self.queryRequest(
      DashboardDependenciesQueryRequestParts(
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
  ) -> DependencyUpdatesQueryRequest {
    Self.queryRequest(
      DashboardDependenciesQueryRequestParts(
        authors: authors,
        organizations: [],
        repositories: [repository],
        excludeRepositories: excludeRepositories,
        cacheMaxAgeSeconds: preferences.cacheMaxAgeSeconds,
        forceRefresh: forceRefresh
      )
    )
  }

  fileprivate static func queryRequest(_ parts: DashboardDependenciesQueryRequestParts)
    -> DependencyUpdatesQueryRequest
  {
    DependencyUpdatesQueryRequest(
      authors: parts.authors,
      organizations: parts.organizations,
      repositories: parts.repositories,
      excludeRepositories: parts.excludeRepositories,
      forceRefresh: parts.forceRefresh,
      cacheMaxAgeSeconds: max(
        parts.cacheMaxAgeSeconds,
        DashboardDependenciesPreferences.minimumPerRepositoryIntervalSeconds
      )
    )
  }
}

enum DashboardDependenciesMissingClientState: Equatable {
  case ignore
  case loading
  case error(String)
}

func dashboardDependenciesMissingClientState(
  backgroundRefresh: Bool,
  connectionState: HarnessMonitorStore.ConnectionState
) -> DashboardDependenciesMissingClientState {
  guard !backgroundRefresh else {
    return .ignore
  }
  if connectionState == .connecting {
    return .loading
  }
  return .error("The dependencies route needs a daemon client")
}

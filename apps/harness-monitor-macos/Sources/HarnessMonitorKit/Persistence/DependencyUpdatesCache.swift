import CryptoKit
import Foundation
import SwiftData

public struct DependencyUpdatesCache {
  private let context: ModelContext

  public init(context: ModelContext) {
    self.context = context
  }

  public func load(preferencesHash: String) -> DependencyUpdatesQueryResponse? {
    guard let row = fetchRow(preferencesHash: preferencesHash) else {
      return nil
    }
    do {
      return try row.decodedResponse()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to decode cached dependency updates response; \
        preferences_hash=\(preferencesHash, privacy: .public) \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
      context.delete(row)
      try? context.save()
      return nil
    }
  }

  /// Wholesale replace the cached snapshot for `preferencesHash`. PRs and
  /// repository labels that were present in the prior payload but absent in
  /// `response` drop with the row update; this is the primary cleanup hook.
  public func save(preferencesHash: String, response: DependencyUpdatesQueryResponse) {
    do {
      if let row = fetchRow(preferencesHash: preferencesHash) {
        try row.update(response: response)
      } else {
        let row = try CachedDependencyUpdatesSnapshot.make(
          preferencesHash: preferencesHash,
          response: response
        )
        context.insert(row)
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to persist dependency updates snapshot; \
        preferences_hash=\(preferencesHash, privacy: .public) \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  /// Patch the cached snapshot for `preferencesHash` with the result of a
  /// targeted refresh. Mirrors the daemon's `apply_refresh_to_items` semantics:
  /// missing IDs drop, non-open replacements drop, open replacements update in
  /// place. Returns the reconciled response that the caller can apply to its
  /// `@State` mirror, or `nil` if no cached row exists.
  @discardableResult
  public func applyRefresh(
    preferencesHash: String,
    refresh: DependencyUpdatesRefreshResponse
  ) -> DependencyUpdatesQueryResponse? {
    guard let row = fetchRow(preferencesHash: preferencesHash),
      let cached = try? row.decodedResponse()
    else {
      return nil
    }
    let nextItems = Self.applyRefreshToItems(
      cached.items,
      refresh: refresh
    )
    let nextResponse = DependencyUpdatesQueryResponse(
      fetchedAt: refresh.fetchedAt,
      fromCache: cached.fromCache,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems
    )
    save(preferencesHash: preferencesHash, response: nextResponse)
    return nextResponse
  }

  /// Apply a per-repository query response to the cached snapshot for
  /// `preferencesHash`. Items belonging to other repositories pass through
  /// untouched; the targeted repository's items are wholesale replaced by
  /// `response.items`. Repository labels for the targeted repo are refreshed,
  /// other repos' labels remain. Returns the reconciled response, or `nil` if
  /// no cached row exists for `preferencesHash`.
  @discardableResult
  public func applyPerRepoResponse(
    preferencesHash: String,
    repository: String,
    response: DependencyUpdatesQueryResponse
  ) -> DependencyUpdatesQueryResponse? {
    guard let row = fetchRow(preferencesHash: preferencesHash),
      let cached = try? row.decodedResponse()
    else {
      return nil
    }
    let nextItems = Self.applyPerRepoResponseToItems(
      cached.items,
      repository: repository,
      response: response
    )
    var nextLabels = cached.repositoryLabels
    if let updatedLabels = response.repositoryLabels[repository] {
      nextLabels[repository] = updatedLabels
    }
    let nextResponse = DependencyUpdatesQueryResponse(
      fetchedAt: response.fetchedAt,
      fromCache: cached.fromCache,
      summary: DependencyUpdatesSummary(items: nextItems),
      items: nextItems,
      repositoryLabels: nextLabels
    )
    save(preferencesHash: preferencesHash, response: nextResponse)
    return nextResponse
  }

  public func deleteAll() {
    do {
      let descriptor = FetchDescriptor<CachedDependencyUpdatesSnapshot>()
      let rows = try context.fetch(descriptor)
      for row in rows {
        context.delete(row)
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to clear dependency updates cache; \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  private func fetchRow(preferencesHash: String) -> CachedDependencyUpdatesSnapshot? {
    let descriptor = FetchDescriptor<CachedDependencyUpdatesSnapshot>(
      predicate: #Predicate { $0.preferencesHash == preferencesHash }
    )
    return try? context.fetch(descriptor).first
  }

  /// Apply a targeted refresh to a snapshot's items list. Pure function so
  /// tests can exercise it without a `ModelContext`.
  static func applyRefreshToItems(
    _ items: [DependencyUpdateItem],
    refresh: DependencyUpdatesRefreshResponse
  ) -> [DependencyUpdateItem] {
    let droppedIDs = Set(refresh.missingPullRequestIDs)
    let openItemsByID: [String: DependencyUpdateItem] = Dictionary(
      uniqueKeysWithValues: refresh.items
        .filter { $0.state == .open }
        .map { ($0.pullRequestID, $0) }
    )
    let closedIDs = Set(
      refresh.items.filter { $0.state != .open }.map(\.pullRequestID)
    )
    return items.compactMap { item -> DependencyUpdateItem? in
      if droppedIDs.contains(item.pullRequestID) || closedIDs.contains(item.pullRequestID) {
        return nil
      }
      return openItemsByID[item.pullRequestID] ?? item
    }
  }

  /// Merge a per-repository response into a flat items list.
  ///
  /// - Items for repositories other than `repository` pass through in their
  ///   original order, untouched.
  /// - Items for `repository` whose `pullRequestID` appears in
  ///   `response.items` get replaced in place with the response variant.
  /// - Items for `repository` absent from `response.items` are dropped
  ///   (closed, merged, or no longer matching the query).
  /// - PRs present in `response.items` that were not yet known are appended.
  ///
  /// Pure function so tests can exercise it without a `ModelContext`.
  public static func applyPerRepoResponseToItems(
    _ items: [DependencyUpdateItem],
    repository: String,
    response: DependencyUpdatesQueryResponse
  ) -> [DependencyUpdateItem] {
    let responseByID: [String: DependencyUpdateItem] = Dictionary(
      uniqueKeysWithValues: response.items.map { ($0.pullRequestID, $0) }
    )
    var seenIDs = Set<String>()
    var result: [DependencyUpdateItem] = []
    result.reserveCapacity(items.count + response.items.count)
    for item in items {
      if item.repository != repository {
        result.append(item)
        continue
      }
      if let updated = responseByID[item.pullRequestID] {
        result.append(updated)
        seenIDs.insert(updated.pullRequestID)
      }
    }
    for newItem in response.items where !seenIDs.contains(newItem.pullRequestID) {
      result.append(newItem)
    }
    return result
  }
}

extension DependencyUpdatesCache {
  /// Stable cache key derived from the bucket-determining fields of the
  /// daemon query request (authors / orgs / repos / excludes). Freshness
  /// inputs (`forceRefresh`, `cacheMaxAgeSeconds`) are excluded because they
  /// do not change which PRs the response represents.
  public static func preferencesHash(
    for request: DependencyUpdatesQueryRequest
  ) -> String {
    let normalized = DependencyUpdatesCacheKey(
      authors: request.authors.sorted(),
      organizations: request.organizations.sorted(),
      repositories: request.repositories.sorted(),
      excludeRepositories: request.excludeRepositories.sorted()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(normalized)) ?? Data()
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

public actor DependencyUpdatesCachePersistenceWriter {
  private let modelContainer: ModelContainer

  public init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  public func saveResponse(
    preferencesHash: String,
    response: DependencyUpdatesQueryResponse
  ) {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    DependencyUpdatesCache(context: context).save(
      preferencesHash: preferencesHash,
      response: response
    )
    RepositoryLabelsCache(context: context).upsert(response.repositoryLabels)
  }

  public func applyRefresh(
    preferencesHash: String,
    refresh: DependencyUpdatesRefreshResponse
  ) {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    _ = DependencyUpdatesCache(context: context).applyRefresh(
      preferencesHash: preferencesHash,
      refresh: refresh
    )
  }

  public func applyPerRepoResponse(
    preferencesHash: String,
    repository: String,
    response: DependencyUpdatesQueryResponse,
    fallbackResponse: DependencyUpdatesQueryResponse
  ) {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    let cache = DependencyUpdatesCache(context: context)
    let merged = cache.applyPerRepoResponse(
      preferencesHash: preferencesHash,
      repository: repository,
      response: response
    )
    if merged == nil {
      cache.save(preferencesHash: preferencesHash, response: fallbackResponse)
    }
    RepositoryLabelsCache(context: context).upsert(response.repositoryLabels)
  }
}

private struct DependencyUpdatesCacheKey: Codable {
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
}

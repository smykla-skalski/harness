import CryptoKit
import Foundation
import SwiftData

public struct ReviewsCache {
  private let context: ModelContext

  public init(context: ModelContext) {
    self.context = context
  }

  public func load(preferencesHash: String) -> ReviewsQueryResponse? {
    guard let row = fetchRow(preferencesHash: preferencesHash) else {
      return nil
    }
    do {
      return try row.decodedResponse()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to decode cached reviews response; \
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
  public func save(preferencesHash: String, response: ReviewsQueryResponse) {
    do {
      if let row = fetchRow(preferencesHash: preferencesHash) {
        try row.update(response: response)
      } else {
        let row = try CachedReviewsSnapshot.make(
          preferencesHash: preferencesHash,
          response: response
        )
        context.insert(row)
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to persist reviews snapshot; \
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
    refresh: ReviewsRefreshResponse
  ) -> ReviewsQueryResponse? {
    guard let row = fetchRow(preferencesHash: preferencesHash),
      let cached = try? row.decodedResponse()
    else {
      return nil
    }
    let nextItems = Self.applyRefreshToItems(
      cached.items,
      refresh: refresh
    )
    let nextResponse = ReviewsQueryResponse(
      fetchedAt: refresh.fetchedAt,
      fromCache: cached.fromCache,
      summary: ReviewsSummary(items: nextItems),
      items: nextItems,
      repositoryLabels: cached.repositoryLabels,
      viewerLogin: cached.viewerLogin
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
    response: ReviewsQueryResponse
  ) -> ReviewsQueryResponse? {
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
    if let responseLabelKey = Self.matchingRepositoryKey(
      for: repository,
      in: response.repositoryLabels.keys
    ),
      let updatedLabels = response.repositoryLabels[responseLabelKey],
      !updatedLabels.isEmpty
    {
      let targetLabelKey =
        Self.matchingRepositoryKey(for: repository, in: nextLabels.keys) ?? responseLabelKey
      nextLabels[targetLabelKey] = updatedLabels
    }
    let nextResponse = ReviewsQueryResponse(
      fetchedAt: response.fetchedAt,
      fromCache: cached.fromCache,
      summary: ReviewsSummary(items: nextItems),
      items: nextItems,
      repositoryLabels: nextLabels,
      viewerLogin: response.viewerLogin ?? cached.viewerLogin
    )
    save(preferencesHash: preferencesHash, response: nextResponse)
    return nextResponse
  }

  public func deleteAll() {
    do {
      let descriptor = FetchDescriptor<CachedReviewsSnapshot>()
      let rows = try context.fetch(descriptor)
      for row in rows {
        context.delete(row)
      }
      try context.save()
    } catch {
      HarnessMonitorLogger.store.warning(
        """
        Failed to clear reviews cache; \
        error=\(String(reflecting: error), privacy: .public)
        """
      )
    }
  }

  private func fetchRow(preferencesHash: String) -> CachedReviewsSnapshot? {
    let descriptor = FetchDescriptor<CachedReviewsSnapshot>(
      predicate: #Predicate { $0.preferencesHash == preferencesHash }
    )
    return try? context.fetch(descriptor).first
  }

  /// Apply a targeted refresh to a snapshot's items list. Pure function so
  /// tests can exercise it without a `ModelContext`.
  static func applyRefreshToItems(
    _ items: [ReviewItem],
    refresh: ReviewsRefreshResponse
  ) -> [ReviewItem] {
    applyReviewsRefresh(to: items, refresh: refresh)
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
    _ items: [ReviewItem],
    repository: String,
    response: ReviewsQueryResponse
  ) -> [ReviewItem] {
    let currentItems = normalizedReviewItems(items)
    let refreshedItems = normalizedReviewItems(response.items)
    let repositoryKey = repositoryTrackingKey(repository)
    let responseByID: [String: ReviewItem] = Dictionary(
      uniqueKeysWithValues: refreshedItems.map { ($0.pullRequestID, $0) }
    )
    var seenIDs = Set<String>()
    var result: [ReviewItem] = []
    result.reserveCapacity(currentItems.count + refreshedItems.count)
    for item in currentItems {
      if repositoryTrackingKey(item.repository) != repositoryKey {
        result.append(item)
        continue
      }
      if let updated = responseByID[item.pullRequestID] {
        result.append(updated)
        seenIDs.insert(updated.pullRequestID)
      }
    }
    for newItem in refreshedItems where !seenIDs.contains(newItem.pullRequestID) {
      result.append(newItem)
    }
    return normalizedReviewItems(result)
  }

  private static func repositoryTrackingKey(_ repository: String) -> String {
    repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func matchingRepositoryKey<S: Sequence>(
    for repository: String,
    in repositories: S
  ) -> String? where S.Element == String {
    let repositoryKey = repositoryTrackingKey(repository)
    return repositories.first { repositoryTrackingKey($0) == repositoryKey }
  }
}

extension ReviewsCache {
  /// Stable cache key derived from the fields that change the review rows the
  /// app can hydrate. Freshness inputs (`forceRefresh`, `cacheMaxAgeSeconds`)
  /// are excluded because they do not change response content.
  public static func preferencesHash(
    for request: ReviewsQueryRequest
  ) -> String {
    let normalized = ReviewsCacheKey(
      authors: request.authors.sorted(),
      organizations: request.organizations.sorted(),
      repositories: request.repositories.sorted(),
      excludeRepositories: request.excludeRepositories.sorted(),
      backportDetectionEnabled: request.backportDetectionEnabled,
      backportPatterns: request.backportPatterns
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(normalized)) ?? Data()
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

public actor ReviewsCachePersistenceWriter {
  private let modelContainer: ModelContainer

  public init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  public func saveResponse(
    preferencesHash: String,
    response: ReviewsQueryResponse
  ) {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    ReviewsCache(context: context).save(
      preferencesHash: preferencesHash,
      response: response
    )
    RepositoryLabelsCache(context: context).upsert(response.repositoryLabels)
  }

  public func applyRefresh(
    preferencesHash: String,
    refresh: ReviewsRefreshResponse
  ) {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    _ = ReviewsCache(context: context).applyRefresh(
      preferencesHash: preferencesHash,
      refresh: refresh
    )
  }

  public func applyPerRepoResponse(
    preferencesHash: String,
    repository: String,
    response: ReviewsQueryResponse,
    fallbackResponse: ReviewsQueryResponse
  ) {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    let cache = ReviewsCache(context: context)
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

  public func recordRepoSyncedAt(
    preferencesHash: String,
    repository: String,
    syncedAt: Date = .now
  ) {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    ReviewsRepoSyncStateCache(context: context).recordSyncedAt(
      preferencesHash: preferencesHash,
      repository: repository,
      syncedAt: syncedAt
    )
  }
}

private struct ReviewsCacheKey: Codable {
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
  let backportDetectionEnabled: Bool
  let backportPatterns: [String]
}

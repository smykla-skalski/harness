import CryptoKit
import Foundation
import SwiftData

@MainActor
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

private struct DependencyUpdatesCacheKey: Codable {
  let authors: [String]
  let organizations: [String]
  let repositories: [String]
  let excludeRepositories: [String]
}

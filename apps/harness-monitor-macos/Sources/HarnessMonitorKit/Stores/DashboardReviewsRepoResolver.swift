import Foundation

/// Resolves the deduped, sorted set of `owner/name` repositories the
/// per-repository scheduler should sync.
///
/// Inputs are the primitive bucket fields from preferences (explicit repos,
/// organizations, excludes, expand flag). When `expandOrganizations` is true,
/// the resolver calls the daemon's catalog endpoint once per org and caches
/// the result for the lifetime of the resolver (use `invalidate()` to drop
/// the cache, e.g. when the user changes orgs).
public actor DashboardReviewsRepoResolver {
  private let client: any HarnessMonitorReviewsClientProtocol
  private var cachedOrgRepositories: [String: [String]] = [:]

  public init(client: any HarnessMonitorReviewsClientProtocol) {
    self.client = client
  }

  /// Resolve the repositories to schedule per-repo syncs against.
  ///
  /// - Parameters:
  ///   - explicitRepositories: `owner/name` entries the user typed in directly.
  ///   - organizations: org logins to resolve via the daemon catalog
  ///     endpoint when `expandOrganizations` is true.
  ///   - excludeRepositories: `owner/name` entries to drop from the result.
  ///   - expandOrganizations: when true, calls the daemon catalog endpoint
  ///     once per org; when false, ignores `organizations` entirely.
  /// - Returns: deduped, sorted `[String]` of `owner/name`.
  public func resolveRepositories(
    explicitRepositories: [String],
    organizations: [String],
    excludeRepositories: [String],
    expandOrganizations: Bool
  ) async throws -> [String] {
    var resolved = Set(explicitRepositories)
    if expandOrganizations {
      for org in organizations {
        let repositories = try await fetchOrCacheOrganization(org)
        resolved.formUnion(repositories)
      }
    }
    resolved.subtract(excludeRepositories)
    return resolved.sorted { lhs, rhs in
      lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
  }

  /// Drop the cached `org -> repositories` mapping so the next resolve call
  /// re-fetches every org.
  public func invalidate() {
    cachedOrgRepositories.removeAll()
  }

  /// Number of distinct orgs currently held in cache. Test seam.
  public var cachedOrganizationCount: Int {
    cachedOrgRepositories.count
  }

  private func fetchOrCacheOrganization(_ organization: String) async throws -> [String] {
    if let cached = cachedOrgRepositories[organization] {
      return cached
    }
    let response = try await client.catalogReviewRepositories(
      request: ReviewsRepositoryCatalogRequest(organization: organization)
    )
    cachedOrgRepositories[organization] = response.repositories
    return response.repositories
  }
}

import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews repo resolver")
struct DashboardReviewsRepoResolverTests {
  @Test("explicit repositories pass through and dedupe")
  func explicitOnly() async throws {
    let client = RepoCatalogStub(orgs: [:])
    let resolver = DashboardReviewsRepoResolver(client: client)
    let result = try await resolver.resolveRepositories(
      explicitRepositories: ["acme/api", "acme/web", "acme/api"],
      organizations: [],
      excludeRepositories: [],
      expandOrganizations: true
    )
    #expect(result == ["acme/api", "acme/web"])
  }

  @Test("organizations expand into their repos when expansion is on")
  func orgExpansionOn() async throws {
    let client = RepoCatalogStub(orgs: [
      "acme": ["acme/api", "acme/web"],
      "contoso": ["contoso/lib"],
    ])
    let resolver = DashboardReviewsRepoResolver(client: client)
    let result = try await resolver.resolveRepositories(
      explicitRepositories: ["explicit/repo"],
      organizations: ["acme", "contoso"],
      excludeRepositories: [],
      expandOrganizations: true
    )
    #expect(result == ["acme/api", "acme/web", "contoso/lib", "explicit/repo"])
  }

  @Test("organizations are ignored when expansion is off")
  func orgExpansionOff() async throws {
    let client = RepoCatalogStub(orgs: ["acme": ["acme/api"]])
    let resolver = DashboardReviewsRepoResolver(client: client)
    let result = try await resolver.resolveRepositories(
      explicitRepositories: ["explicit/repo"],
      organizations: ["acme"],
      excludeRepositories: [],
      expandOrganizations: false
    )
    #expect(result == ["explicit/repo"])
    #expect(client.fetchCount(for: "acme") == 0)
  }

  @Test("excludes filter the final result")
  func excludesFilter() async throws {
    let client = RepoCatalogStub(orgs: [
      "acme": ["acme/api", "acme/web", "acme/legacy"]
    ])
    let resolver = DashboardReviewsRepoResolver(client: client)
    let result = try await resolver.resolveRepositories(
      explicitRepositories: [],
      organizations: ["acme"],
      excludeRepositories: ["acme/legacy"],
      expandOrganizations: true
    )
    #expect(result == ["acme/api", "acme/web"])
  }

  @Test("dedupes when an org repo also appears explicitly")
  func dedupeAcrossOrgAndExplicit() async throws {
    let client = RepoCatalogStub(orgs: ["acme": ["acme/api", "acme/web"]])
    let resolver = DashboardReviewsRepoResolver(client: client)
    let result = try await resolver.resolveRepositories(
      explicitRepositories: ["acme/api"],
      organizations: ["acme"],
      excludeRepositories: [],
      expandOrganizations: true
    )
    #expect(result == ["acme/api", "acme/web"])
  }

  @Test("catalog is called once per org per resolver lifetime")
  func catalogCachedPerOrg() async throws {
    let client = RepoCatalogStub(orgs: ["acme": ["acme/api"]])
    let resolver = DashboardReviewsRepoResolver(client: client)
    _ = try await resolver.resolveRepositories(
      explicitRepositories: [],
      organizations: ["acme"],
      excludeRepositories: [],
      expandOrganizations: true
    )
    _ = try await resolver.resolveRepositories(
      explicitRepositories: [],
      organizations: ["acme"],
      excludeRepositories: [],
      expandOrganizations: true
    )
    #expect(client.fetchCount(for: "acme") == 1)
    let cachedCount = await resolver.cachedOrganizationCount
    #expect(cachedCount == 1)
  }

  @Test("invalidate refetches org catalog on the next resolve")
  func invalidateRefetches() async throws {
    let client = RepoCatalogStub(orgs: ["acme": ["acme/api"]])
    let resolver = DashboardReviewsRepoResolver(client: client)
    _ = try await resolver.resolveRepositories(
      explicitRepositories: [],
      organizations: ["acme"],
      excludeRepositories: [],
      expandOrganizations: true
    )
    await resolver.invalidate()
    _ = try await resolver.resolveRepositories(
      explicitRepositories: [],
      organizations: ["acme"],
      excludeRepositories: [],
      expandOrganizations: true
    )
    #expect(client.fetchCount(for: "acme") == 2)
  }
}

private final class RepoCatalogStub: HarnessMonitorReviewsClientProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var orgs: [String: [String]]
  private var fetchCounts: [String: Int] = [:]

  init(orgs: [String: [String]]) {
    self.orgs = orgs
  }

  func fetchCount(for organization: String) -> Int {
    lock.withLock { fetchCounts[organization] ?? 0 }
  }

  func catalogReviewRepositories(
    request: ReviewsRepositoryCatalogRequest
  ) async throws -> ReviewsRepositoryCatalogResponse {
    let repositories: [String] = lock.withLock {
      fetchCounts[request.organization, default: 0] += 1
      return orgs[request.organization] ?? []
    }
    return ReviewsRepositoryCatalogResponse(
      organization: request.organization,
      repositories: repositories
    )
  }
}

@Suite("Dashboard reviews tracked repositories")
struct DashboardReviewsTrackedRepositoriesTests {
  @Test("visible repositories missing from the resolver are appended and excludes still win")
  func visibleRepositoriesAreAppended() {
    let repositories = dashboardReviewsTrackedRepositories(
      resolvedRepositories: ["kong/gateway-operator"],
      visibleRepositories: ["Kong/kong-mesh", "Kong/meshctl"],
      excludeRepositories: ["kong/meshctl"]
    )

    #expect(repositories == ["kong/gateway-operator", "Kong/kong-mesh"])
  }

  @Test("tracked repositories dedupe case-insensitively while preserving resolver order")
  func trackedRepositoriesDedupeCaseInsensitively() {
    let repositories = dashboardReviewsTrackedRepositories(
      resolvedRepositories: ["kong/kong-mesh", "kong/gateway-operator"],
      visibleRepositories: ["Kong/kong-mesh", "KONG/KONG-MESH", "Kong/gateway-operator"],
      excludeRepositories: []
    )

    #expect(repositories == ["kong/kong-mesh", "kong/gateway-operator"])
  }

  @Test("hydrated last-synced lookup matches repository case-insensitively")
  func hydratedLastSyncedAtMatchesCaseInsensitively() {
    let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let hydrated = ["kong/kong-mesh": syncedAt]

    #expect(
      dashboardReviewsHydratedLastSyncedAt(
        repository: "Kong/kong-mesh",
        hydratedStates: hydrated
      ) == syncedAt
    )
  }
}

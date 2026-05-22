import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies preferences")
struct DashboardReviewsPreferencesTests {
  @Test("default initializer produces the documented defaults")
  func defaultsMatchDocumentation() {
    let prefs = DashboardReviewsPreferences()
    #expect(prefs.refreshIntervalSeconds == 300)
    #expect(prefs.perRepositoryIntervalSeconds == 300)
    #expect(prefs.maxConcurrentRepositoryFetches == 2)
    #expect(prefs.expandOrganizations)
  }

  @Test("legacy stored preferences migrate the polling interval into the per-repo field")
  func legacyIntervalMigratesIntoPerRepoField() throws {
    let legacy = """
      {
        "authorsText": "renovate[bot]",
        "refreshIntervalSeconds": 900
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: legacy)
    #expect(prefs.refreshIntervalSeconds == 900)
    #expect(
      prefs.perRepositoryIntervalSeconds == 900,
      "missing perRepositoryIntervalSeconds must fall back to refreshIntervalSeconds"
    )
    #expect(prefs.maxConcurrentRepositoryFetches == 2)
    #expect(prefs.expandOrganizations)
  }

  @Test("explicit per-repo interval wins over legacy refreshIntervalSeconds")
  func explicitPerRepoIntervalWins() throws {
    let payload = """
      {
        "refreshIntervalSeconds": 900,
        "perRepositoryIntervalSeconds": 120,
        "maxConcurrentRepositoryFetches": 4,
        "expandOrganizations": false
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: payload)
    #expect(prefs.refreshIntervalSeconds == 900)
    #expect(prefs.perRepositoryIntervalSeconds == 120)
    #expect(prefs.maxConcurrentRepositoryFetches == 4)
    #expect(!prefs.expandOrganizations)
  }

  @Test("normalized clamps interval and concurrency into safe bounds")
  func normalizedClampsBounds() {
    var prefs = DashboardReviewsPreferences()
    prefs.perRepositoryIntervalSeconds = 5
    prefs.maxConcurrentRepositoryFetches = 0
    let lowClamped = prefs.normalized()
    #expect(
      lowClamped.perRepositoryIntervalSeconds
        == DashboardReviewsPreferences.minimumPerRepositoryIntervalSeconds
    )
    #expect(
      lowClamped.maxConcurrentRepositoryFetches
        == DashboardReviewsPreferences.minimumConcurrentRepositoryFetches
    )

    prefs.perRepositoryIntervalSeconds = 10_000
    prefs.maxConcurrentRepositoryFetches = 99
    let highClamped = prefs.normalized()
    #expect(
      highClamped.perRepositoryIntervalSeconds
        == DashboardReviewsPreferences.maximumPerRepositoryIntervalSeconds
    )
    #expect(
      highClamped.maxConcurrentRepositoryFetches
        == DashboardReviewsPreferences.maximumConcurrentRepositoryFetches
    )
  }

  @Test("per-repo query request scopes to a single repository and strips orgs")
  func perRepositoryRequestShape() {
    var prefs = DashboardReviewsPreferences()
    prefs.authorsText = "renovate[bot], dependabot[bot]"
    prefs.organizationsText = "acme, contoso"
    prefs.repositoriesText = "acme/api, acme/web"
    prefs.excludeRepositoriesText = "acme/legacy"

    let request = prefs.perRepositoryQueryRequest(for: "acme/web", forceRefresh: true)
    #expect(request.repositories == ["acme/web"])
    #expect(request.organizations.isEmpty)
    #expect(request.excludeRepositories == ["acme/legacy"])
    #expect(request.authors.sorted() == ["dependabot[bot]", "renovate[bot]"].sorted())
    #expect(request.forceRefresh)
  }

  @Test("re-encoding new preferences round-trips through Codable")
  func encodingRoundTripsNewFields() throws {
    var prefs = DashboardReviewsPreferences()
    prefs.perRepositoryIntervalSeconds = 180
    prefs.maxConcurrentRepositoryFetches = 5
    prefs.expandOrganizations = false

    let encoded = prefs.encodedString
    let decoded = DashboardReviewsPreferences.decode(from: encoded)
    #expect(decoded.perRepositoryIntervalSeconds == 180)
    #expect(decoded.maxConcurrentRepositoryFetches == 5)
    #expect(!decoded.expandOrganizations)
  }
}

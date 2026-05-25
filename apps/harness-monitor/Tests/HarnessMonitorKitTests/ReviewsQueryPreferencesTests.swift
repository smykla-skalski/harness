import HarnessMonitorKit
import XCTest

final class ReviewsQueryPreferencesTests: XCTestCase {
  func testDecodesDashboardStorageIntoScopedQueryRequest() {
    let storedValue = """
      {
        "authorsText": "alice, bob, alice",
        "organizationsText": "octo\\nacme",
        "repositoriesText": "octo/repo, acme/widgets",
        "excludeRepositoriesText": "acme/legacy",
        "cacheMaxAgeSeconds": 10
      }
      """

    let request = ReviewsQueryPreferences(storedValue: storedValue)
      .queryRequest(forceRefresh: true)

    XCTAssertEqual(request?.authors, ["alice", "bob"])
    XCTAssertEqual(request?.organizations, ["octo", "acme"])
    XCTAssertEqual(request?.repositories, ["octo/repo", "acme/widgets"])
    XCTAssertEqual(request?.excludeRepositories, ["acme/legacy"])
    XCTAssertEqual(request?.forceRefresh, true)
    XCTAssertEqual(
      request?.cacheMaxAgeSeconds,
      ReviewsQueryPreferences.minimumCacheMaxAgeSeconds
    )
  }

  func testRejectsEmptyDashboardScope() {
    let storedValue = """
      {
        "authorsText": "alice",
        "organizationsText": "",
        "repositoriesText": "",
        "excludeRepositoriesText": "octo/old"
      }
      """

    XCTAssertNil(ReviewsQueryPreferences(storedValue: storedValue).queryRequest())
  }

  func testStoreReadsDashboardPreferencesFromDefaults() {
    let suiteName = "io.harnessmonitor.reviews-query-preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
      #"{"repositoriesText":"octo/repo","cacheMaxAgeSeconds":900}"#,
      forKey: ReviewsQueryPreferences.storageKey
    )

    let store = ReviewsQueryPreferenceStore(defaults: defaults)
    let request = store.queryRequest()

    XCTAssertEqual(request?.repositories, ["octo/repo"])
    XCTAssertEqual(request?.cacheMaxAgeSeconds, 900)
  }
}

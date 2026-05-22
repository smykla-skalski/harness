import Foundation
import XCTest

@testable import HarnessMonitorKit

final class ReviewBodyStoreTests: XCTestCase {
  private struct BodyStoreFixture {
    let store: ReviewBodyStore
    let suite: String
  }

  private func makeStore() -> BodyStoreFixture {
    let suite = "ReviewBodyStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let key = "test-bodies"
    return BodyStoreFixture(
      store: ReviewBodyStore(defaults: defaults, key: key),
      suite: suite
    )
  }

  func testMissingEntryReturnsNil() {
    let fixture = makeStore()
    defer { UserDefaults().removePersistentDomain(forName: fixture.suite) }
    XCTAssertNil(fixture.store.cached(forPullRequestID: "PR_1", since: "2026-05-21T00:00:00Z"))
  }

  func testFreshEntryRoundTrips() {
    let fixture = makeStore()
    defer { UserDefaults().removePersistentDomain(forName: fixture.suite) }
    fixture.store.store(
      pullRequestID: "PR_1",
      body: "Hello",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:10Z"
    )
    let entry = fixture.store.cached(
      forPullRequestID: "PR_1",
      since: "2026-05-21T00:00:00Z"
    )
    XCTAssertEqual(entry?.body, "Hello")
    XCTAssertEqual(entry?.prUpdatedAt, "2026-05-21T00:00:00Z")
  }

  func testStaleEntryReturnsNilWhenPRWasUpdated() {
    let fixture = makeStore()
    defer { UserDefaults().removePersistentDomain(forName: fixture.suite) }
    fixture.store.store(
      pullRequestID: "PR_1",
      body: "Old body",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:10Z"
    )
    XCTAssertNil(
      fixture.store.cached(
        forPullRequestID: "PR_1",
        since: "2026-05-21T00:05:00Z"
      ),
      "cached entry should be invalid when PR updated_at advances past prUpdatedAt"
    )
  }

  func testEqualTimestampStaysFresh() {
    let fixture = makeStore()
    defer { UserDefaults().removePersistentDomain(forName: fixture.suite) }
    fixture.store.store(
      pullRequestID: "PR_1",
      body: "Hello",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:10Z"
    )
    XCTAssertNotNil(
      fixture.store.cached(
        forPullRequestID: "PR_1",
        since: "2026-05-21T00:00:00Z"
      )
    )
  }

  func testStorePersistsAcrossInstances() async {
    let suite = "ReviewBodyStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let writer = ReviewBodyStore(defaults: defaults, key: "k")
    writer.store(
      pullRequestID: "PR_1",
      body: "Persisted",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:10Z"
    )
    // Persist queue is background; give it a moment to flush.
    try? await Task.sleep(nanoseconds: 50_000_000)

    let reader = ReviewBodyStore(defaults: defaults, key: "k")
    let entry = reader.cached(forPullRequestID: "PR_1")
    XCTAssertEqual(entry?.body, "Persisted")
  }

  func testClearWipesAllEntries() {
    let fixture = makeStore()
    defer { UserDefaults().removePersistentDomain(forName: fixture.suite) }
    fixture.store.store(
      pullRequestID: "PR_1",
      body: "Hello",
      prUpdatedAt: "2026-05-21T00:00:00Z",
      fetchedAt: "2026-05-21T00:00:10Z"
    )
    fixture.store.clear()
    XCTAssertNil(fixture.store.cached(forPullRequestID: "PR_1"))
  }
}

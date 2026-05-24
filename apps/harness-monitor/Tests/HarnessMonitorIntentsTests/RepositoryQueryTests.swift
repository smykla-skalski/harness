import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class RepositoryQueryTests: XCTestCase {
  private var suiteName: String!

  override func setUp() {
    super.setUp()
    suiteName = "io.harnessmonitor.test.repoquery.\(UUID().uuidString)"
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    suiteName = nil
    super.tearDown()
  }

  private func makeRecorder() -> IntentDonationRecorder {
    IntentDonationRecorder(
      capacity: 20,
      defaults: UserDefaults(suiteName: suiteName),
      storageKey: "test-donations"
    )
  }

  func testSuggestedEntitiesReturnsParsedEntities() async throws {
    let stub = StubRepositorySource(
      suggestedResult: ["octo/repo", "acme/widgets"]
    )
    let query = RepositoryQuery(source: stub)

    let result = try await query.suggestedEntities()

    XCTAssertEqual(result.map(\.id), ["octo/repo", "acme/widgets"])
    XCTAssertEqual(result.map(\.owner), ["octo", "acme"])
  }

  func testSuggestedEntitiesSkipsMalformedIDs() async throws {
    let stub = StubRepositorySource(suggestedResult: ["octo/repo", "broken", ""])
    let query = RepositoryQuery(source: stub)

    let result = try await query.suggestedEntities()

    XCTAssertEqual(result.map(\.id), ["octo/repo"])
  }

  func testEntitiesForReturnsOnlyAvailableIDs() async throws {
    let stub = StubRepositorySource(suggestedResult: ["octo/repo", "acme/widgets"])
    let query = RepositoryQuery(source: stub)

    let result = try await query.entities(for: ["octo/repo", "stale/repo"])

    XCTAssertEqual(result.map(\.id), ["octo/repo"])
  }

  func testEntitiesMatchingFallsBackToSuggestedWhenQueryBlank() async throws {
    let stub = StubRepositorySource(suggestedResult: ["octo/repo"])
    let query = RepositoryQuery(source: stub)

    let result = try await query.entities(matching: "   ")

    XCTAssertEqual(result.map(\.id), ["octo/repo"])
    let recordedSearches = await stub.recordedSearchQueries
    XCTAssertTrue(recordedSearches.isEmpty)
  }

  func testEntitiesMatchingForwardsTrimmedQueryToSource() async throws {
    let stub = StubRepositorySource(searchResult: ["octo/repo"])
    let query = RepositoryQuery(source: stub)

    let result = try await query.entities(matching: "  octo  ")

    XCTAssertEqual(result.map(\.id), ["octo/repo"])
    let recordedSearches = await stub.recordedSearchQueries
    XCTAssertEqual(recordedSearches, ["octo"])
  }

  func testSuggestedEntitiesBumpsRecentlyDonatedReposToFront() async throws {
    let stub = StubRepositorySource(
      suggestedResult: ["acme/widgets", "octo/repo", "ibm/db"]
    )
    let recorder = makeRecorder()
    await recorder.recordDonation(kind: .repository, id: "octo/repo")
    let query = RepositoryQuery(source: stub, donationRecorder: recorder)

    let result = try await query.suggestedEntities()

    XCTAssertEqual(
      result.map(\.id),
      ["octo/repo", "acme/widgets", "ibm/db"],
      "donated repo should move to the front while the rest keep daemon order"
    )
  }

  func testSuggestedEntitiesPreservesOrderWithoutDonations() async throws {
    let stub = StubRepositorySource(
      suggestedResult: ["acme/widgets", "octo/repo"]
    )
    let query = RepositoryQuery(source: stub, donationRecorder: makeRecorder())

    let result = try await query.suggestedEntities()

    XCTAssertEqual(result.map(\.id), ["acme/widgets", "octo/repo"])
  }

  func testSuggestedEntitiesIgnoresPullRequestKindDonations() async throws {
    let stub = StubRepositorySource(
      suggestedResult: ["acme/widgets", "octo/repo"]
    )
    let recorder = makeRecorder()
    await recorder.recordDonation(kind: .pullRequest, id: "octo/repo")
    let query = RepositoryQuery(source: stub, donationRecorder: recorder)

    let result = try await query.suggestedEntities()

    XCTAssertEqual(
      result.map(\.id),
      ["acme/widgets", "octo/repo"],
      "a PR-kind donation must not bias the repository surface"
    )
  }
}

actor StubRepositorySource: RepositorySource {
  private let suggestedResult: [String]
  private let searchResult: [String]
  private(set) var recordedSearchQueries: [String] = []

  init(suggestedResult: [String] = [], searchResult: [String] = []) {
    self.suggestedResult = suggestedResult
    self.searchResult = searchResult
  }

  func suggested() async throws -> [String] {
    suggestedResult
  }

  func search(query: String) async throws -> [String] {
    recordedSearchQueries.append(query)
    return searchResult
  }
}

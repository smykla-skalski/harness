import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class RepositoryQueryTests: XCTestCase {
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

import AppIntents
import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class RefreshReviewsIntentTests: XCTestCase {
  func testRefreshRepositoryReturnsZeroForBlankInput() async throws {
    let stub = StubReviewsRefreshSource(repositoryResult: 5)
    let intent = RefreshRepositoryIntent(repository: "   \t", source: stub)

    let count = try await intent.resolveRefreshCount()

    XCTAssertEqual(count, 0)
    let recorded = await stub.recordedRepositories
    XCTAssertTrue(recorded.isEmpty, "blank input should not call the source")
  }

  func testRefreshRepositoryTrimsAndForwardsToSource() async throws {
    let stub = StubReviewsRefreshSource(repositoryResult: 3)
    let intent = RefreshRepositoryIntent(
      repository: "  octo/Hello-World  ",
      source: stub
    )

    let count = try await intent.resolveRefreshCount()

    XCTAssertEqual(count, 3)
    let recorded = await stub.recordedRepositories
    XCTAssertEqual(recorded, ["octo/Hello-World"])
  }

  func testRefreshAllInvokesRefreshAllOnSource() async throws {
    let stub = StubReviewsRefreshSource()
    let intent = RefreshAllReposIntent(source: stub)

    _ = try await intent.perform()

    let count = await stub.refreshAllCount
    XCTAssertEqual(count, 1)
  }

  func testRefreshRepositoryDialogMentionsRepository() {
    let dialog = RefreshRepositoryIntent.dialog(for: 3, repository: "octo/repo")
    let dump = String(describing: dialog)
    XCTAssertTrue(
      dump.contains("octo/repo"),
      "dialog should mention the repository name: \(dump)"
    )
  }
}

actor StubReviewsRefreshSource: ReviewsRefreshSource {
  private let repositoryResult: Int
  private(set) var recordedRepositories: [String] = []
  private(set) var refreshAllCount: Int = 0

  init(repositoryResult: Int = 0) {
    self.repositoryResult = repositoryResult
  }

  func refreshAll() async throws {
    refreshAllCount += 1
  }

  func refreshRepository(_ repository: String) async throws -> Int {
    recordedRepositories.append(repository)
    return repositoryResult
  }
}

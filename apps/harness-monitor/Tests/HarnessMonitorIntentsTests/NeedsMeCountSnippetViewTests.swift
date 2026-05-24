import HarnessMonitorKit
import SwiftUI
import XCTest

@testable import HarnessMonitorIntents

@MainActor
final class NeedsMeCountSnippetViewTests: XCTestCase {
  func testSnippetViewAcceptsZeroCount() {
    let view = NeedsMeCountSnippetView(count: 0, topItems: [])
    XCTAssertEqual(view.count, 0)
    XCTAssertTrue(view.topItems.isEmpty)
  }

  func testSnippetViewAcceptsCountAndItems() {
    let items = [makeItem(id: "owner/repo#1", title: "Add docs")]
    let view = NeedsMeCountSnippetView(count: 7, topItems: items)
    XCTAssertEqual(view.count, 7)
    XCTAssertEqual(view.topItems.map(\.pullRequestID), ["owner/repo#1"])
  }

  func testIntentDialogChangesByCount() {
    let zero = String(describing: GetNeedsMeCountIntent.dialog(for: 0))
    let one = String(describing: GetNeedsMeCountIntent.dialog(for: 1))
    let many = String(describing: GetNeedsMeCountIntent.dialog(for: 7))

    XCTAssertTrue(zero.contains("Nothing"))
    XCTAssertTrue(one.contains("1 pull request"))
    XCTAssertTrue(many.contains("7"))
  }

  private func makeItem(id: String, title: String) -> ReviewItem {
    let parts = id.components(separatedBy: "#")
    let repo = parts.first ?? "owner/repo"
    let number = UInt64(parts.count > 1 ? parts[1] : "0") ?? 0
    return ReviewItem(
      pullRequestID: id,
      repositoryID: repo,
      repository: repo,
      number: number,
      title: title,
      url: "https://github.com/\(repo)/pull/\(number)",
      authorLogin: "alice",
      state: .open,
      mergeable: .conflicting,
      reviewStatus: .none,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      labels: [],
      checks: [],
      reviews: [],
      additions: 0,
      deletions: 0,
      createdAt: "2026-05-22T10:00:00Z",
      updatedAt: "2026-05-23T12:00:00Z"
    )
  }
}

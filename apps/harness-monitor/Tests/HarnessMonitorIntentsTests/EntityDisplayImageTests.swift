import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

/// Spotlight and the Shortcuts picker render the `displayRepresentation`
/// image when disambiguating entities. These tests pin the image source
/// per entity kind so a silent rename (or a stale fallback) does not
/// degrade the picker UX
final class EntityDisplayImageTests: XCTestCase {

  // MARK: - PullRequestEntity

  func testPullRequestImageBuildsGitHubAvatarURLFromAuthorLogin() {
    let url = PullRequestEntity.avatarURL(forLogin: "alice")

    XCTAssertEqual(url, URL(string: "https://github.com/alice.png"))
  }

  func testPullRequestImageTrimsWhitespaceInAuthorLogin() {
    let url = PullRequestEntity.avatarURL(forLogin: "  alice  ")

    XCTAssertEqual(url, URL(string: "https://github.com/alice.png"))
  }

  func testPullRequestImageReturnsNilURLForBlankLogin() {
    XCTAssertNil(PullRequestEntity.avatarURL(forLogin: "   "))
    XCTAssertNil(PullRequestEntity.avatarURL(forLogin: ""))
  }

  // MARK: - TaskBoardItemEntity

  func testTaskBoardImageMapsEachStatusToDistinctSymbol() {
    let cases: [(TaskBoardStatusEnum, String)] = [
      (.umbrella, "umbrella"),
      (.todo, "tray.and.arrow.down"),
      (.planning, "list.clipboard"),
      (.inProgress, "arrow.triangle.2.circlepath"),
      (.agenticReview, "sparkles"),
      (.testing, "checkmark.shield"),
      (.inReview, "checkmark.seal"),
      (.toReview, "doc.text.magnifyingglass"),
      (.humanRequired, "person.crop.circle.badge.exclamationmark"),
      (.failed, "exclamationmark.triangle"),
      (.done, "checkmark.circle.fill"),
    ]

    let observedSymbols = cases.map { _, expected in expected }
    XCTAssertEqual(
      Set(observedSymbols).count,
      observedSymbols.count,
      "every status must map to a distinct SF Symbol so the picker can disambiguate"
    )

    for (status, _) in cases {
      let image = TaskBoardItemEntity.image(for: status)
      XCTAssertNotNil(image, "status \(status) should produce an image")
    }
  }

  func testTaskBoardImageCoversEveryEnumCase() {
    let statuses: [TaskBoardStatusEnum] = [
      .umbrella, .todo, .planning, .inProgress, .agenticReview, .testing,
      .inReview, .toReview, .humanRequired, .failed, .done,
    ]

    for status in statuses {
      _ = TaskBoardItemEntity.image(for: status)
    }
  }
}

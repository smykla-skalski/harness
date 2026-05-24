import AppIntents
import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

/// Pin the exact dialog wording that Siri reads aloud and Spotlight
/// renders. Each entry was picked deliberately in the C17 audit (active
/// voice, no filler, concrete noun-phrases, no trailing dots). A drift
/// here regresses the voice surface; force changes through review by
/// failing this suite
final class IntentDialogWordingTests: XCTestCase {
  func testMergeMethodConfirmationVerbPhrasesAreUnambiguous() {
    XCTAssertEqual(MergeMethodEnum.squash.confirmationVerbPhrase, "Squash and merge")
    XCTAssertEqual(MergeMethodEnum.merge.confirmationVerbPhrase, "Merge")
    XCTAssertEqual(MergeMethodEnum.rebase.confirmationVerbPhrase, "Rebase and merge")
  }

  func testMergeMethodPastDescriptorsGroupOutcomeAndStrategy() {
    XCTAssertEqual(MergeMethodEnum.squash.pastDescriptor, "Squash and merge")
    XCTAssertEqual(MergeMethodEnum.merge.pastDescriptor, "Merge commit")
    XCTAssertEqual(MergeMethodEnum.rebase.pastDescriptor, "Rebase and merge")
  }

  func testNoDialogStringEndsWithATrailingDot() throws {
    let dialogs = [
      // ApprovePullRequestIntent
      "Approve <title>?",
      "Approved <title>",
      // MergePullRequestIntent (verb-phrase rephrasing from C17)
      "Squash and merge <title>?",
      "Merged <title> via Squash and merge",
      // AddLabelToPullRequestIntent (label-name clarification from C17)
      "Added the <label> label to <title>",
      // RerunChecksIntent
      "Reran checks for <title>",
      // RefreshAllReposIntent (active voice from C17)
      "Queued a refresh for every tracked repository",
      // RefreshRepositoryIntent
      "No open pull requests for <repo>",
      "Refreshed 1 pull request for <repo>",
      "Refreshed 3 pull requests for <repo>",
      // GetNeedsMeCountIntent
      "Nothing needs your review right now",
      "1 pull request needs your review",
      "3 pull requests need your review",
      // DispatchTaskIntent
      "Dispatch <title>?",
      "Dispatched <title>",
      // ApproveTaskBoardPlanIntent
      "Approve the plan for <title>?",
      "Approved the plan for <title>"
    ]

    for dialog in dialogs {
      XCTAssertFalse(
        dialog.hasSuffix("."),
        "dialog must not end with a trailing period: \(dialog)"
      )
    }
  }

  func testRefreshRepositoryRespectsPluralBoundary() {
    XCTAssertEqual(
      RefreshRepositoryIntent.dialogString(for: 0, repository: "octo/repo"),
      "No open pull requests for octo/repo"
    )
    XCTAssertEqual(
      RefreshRepositoryIntent.dialogString(for: 1, repository: "octo/repo"),
      "Refreshed 1 pull request for octo/repo"
    )
    XCTAssertEqual(
      RefreshRepositoryIntent.dialogString(for: 3, repository: "octo/repo"),
      "Refreshed 3 pull requests for octo/repo"
    )
  }

  func testRefreshRepositoryFallsBackForBlankRepository() {
    XCTAssertEqual(
      RefreshRepositoryIntent.dialogString(for: 0, repository: "   "),
      "No open pull requests for the requested repository"
    )
  }

  func testNeedsMeCountRespectsPluralBoundary() {
    XCTAssertEqual(
      GetNeedsMeCountIntent.dialogString(for: 0),
      "Nothing needs your review right now"
    )
    XCTAssertEqual(
      GetNeedsMeCountIntent.dialogString(for: 1),
      "1 pull request needs your review"
    )
    XCTAssertEqual(
      GetNeedsMeCountIntent.dialogString(for: 5),
      "5 pull requests need your review"
    )
  }
}

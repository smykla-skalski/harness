import Foundation
import HarnessMonitorCore
import HarnessMonitorMirrorStore
import XCTest

@MainActor
final class CommandFormModelTests: XCTestCase {
  private func makeModel(profile: CommandFormProfile) -> CommandFormModel {
    let store = MirrorStore(
      snapshot: .empty(),
      demoModeEnabled: true,
      profile: .phone,
      sharedSnapshotStore: nil
    )
    return CommandFormModel(store: store, profile: profile)
  }

  func testPhoneAgentStartPayload() {
    let model = makeModel(profile: .phone)
    model.kind = .agentStart
    model.agent = "codex"
    model.role = "worker"
    model.prompt = "go"
    let payload = model.makeDraft(confirmationText: "Confirm").payload
    XCTAssertEqual(payload["agent"], "codex")
    XCTAssertEqual(payload["role"], "worker")
    XCTAssertEqual(payload["prompt"], "go")
  }

  func testWatchAgentStartResolvesPromptPreset() {
    let model = makeModel(profile: .watch)
    model.kind = .agentStart
    model.prompt = ""
    model.promptPreset = "summarize"
    let payload = model.makeDraft(confirmationText: "Confirm").payload
    XCTAssertEqual(payload["prompt"], "Summarize the current blocker and next action.")
  }

  func testPhoneTaskBoardDispatchIncludesDryRun() {
    let model = makeModel(profile: .phone)
    model.kind = .taskBoardDispatch
    model.taskStatus = "todo"
    model.dryRun = true
    let payload = model.makeDraft(confirmationText: "Confirm").payload
    XCTAssertEqual(payload["status"], "todo")
    XCTAssertEqual(payload["dryRun"], "true")
  }

  func testWatchTaskBoardDispatchOmitsDryRun() {
    let model = makeModel(profile: .watch)
    model.kind = .taskBoardDispatch
    model.taskStatus = "todo"
    let payload = model.makeDraft(confirmationText: "Confirm").payload
    XCTAssertEqual(payload["status"], "todo")
    XCTAssertNil(payload["dryRun"])
  }

  func testPhoneRefreshReviewsPayload() {
    let model = makeModel(profile: .phone)
    model.kind = .refresh
    model.refreshScope = "reviews"
    model.repository = "octo/repo"
    model.reviewNumber = "5"
    let payload = model.makeDraft(confirmationText: "Confirm").payload
    XCTAssertEqual(payload["scope"], "reviews")
    XCTAssertEqual(payload["repository"], "octo/repo")
    XCTAssertEqual(payload["number"], "5")
  }

  func testManualMergePayload() {
    let model = makeModel(profile: .phone)
    model.kind = .pullRequestMerge
    model.mergeMethod = "squash"
    model.repository = "octo/repo"
    model.reviewNumber = "7"
    let payload = model.makeDraft(confirmationText: "Confirm").payload
    XCTAssertEqual(payload["method"], "squash")
    XCTAssertEqual(payload["repository"], "octo/repo")
    XCTAssertEqual(payload["number"], "7")
  }

  func testPhoneExpiryIsFifteenMinutes() {
    let model = makeModel(profile: .phone)
    model.kind = .refresh
    XCTAssertEqual(model.makeDraft(confirmationText: "Confirm").expiresAfter, 15 * 60)
  }

  func testWatchExpiryIsTenMinutes() {
    let model = makeModel(profile: .watch)
    model.kind = .refresh
    XCTAssertEqual(model.makeDraft(confirmationText: "Confirm").expiresAfter, 10 * 60)
  }

  func testWatchSeedsMergeAuditReason() {
    let model = makeModel(profile: .watch)
    model.kind = .pullRequestMerge
    model.seedDefaultsForKind()
    XCTAssertEqual(model.auditReason, "Confirmed from Apple Watch.")
  }

  func testPhoneDoesNotSeedMergeAuditReason() {
    let model = makeModel(profile: .phone)
    model.kind = .pullRequestMerge
    model.seedDefaultsForKind()
    XCTAssertEqual(model.auditReason, "")
  }
}

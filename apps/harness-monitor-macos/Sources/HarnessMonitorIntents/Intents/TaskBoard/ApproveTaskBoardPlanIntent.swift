import AppIntents
import Foundation
import HarnessMonitorKit

public struct ApproveTaskBoardPlanIntent: AppIntent {
  public static var title: LocalizedStringResource { "Approve Task Plan" }
  public static var description: IntentDescription {
    IntentDescription(
      "Approve the pending plan attached to a Task Board item. Confirms before approving.",
      categoryName: "Task Board",
      searchKeywords: ["approve", "plan", "task", "lgtm"]
    )
  }

  public static let intentApproverIdentity = "harness-intent"

  @Parameter(title: "Task")
  public var item: TaskBoardItemEntity

  let source: TaskBoardItemSource
  let approver: String

  public init() {
    self.source = DaemonTaskBoardItemSource()
    self.approver = Self.intentApproverIdentity
  }

  init(
    item: TaskBoardItemEntity,
    source: TaskBoardItemSource,
    approver: String = Self.intentApproverIdentity
  ) {
    self.source = source
    self.approver = approver
    self.item = item
  }

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requestConfirmation(
      dialog: IntentDialog("Approve the plan for \(item.title)?")
    )
    try await applyApproval()
    return .result(dialog: IntentDialog("Approved the plan for \(item.title)."))
  }

  func applyApproval() async throws {
    try await source.approvePlan(itemID: item.id, approver: approver)
  }
}

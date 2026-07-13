import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("TaskBoardPlanApprovalState derivation")
struct TaskBoardPlanApprovalStateTests {
  @Test("approver present maps to approved regardless of summary")
  func approverMapsToApproved() {
    let planning = TaskBoardPlanningState(
      summary: "did the thing",
      approvedBy: "reviewer",
      approvedAt: "2026-07-13T00:00:00Z"
    )
    #expect(TaskBoardPlanApprovalState(planning: planning) == .approved)
  }

  @Test("empty approver falls through to summary check")
  func emptyApproverIsNotApproved() {
    let planning = TaskBoardPlanningState(summary: "a plan", approvedBy: "", approvedAt: nil)
    #expect(TaskBoardPlanApprovalState(planning: planning) == .submitted)
  }

  @Test("non-empty summary without approver maps to submitted")
  func summaryMapsToSubmitted() {
    let planning = TaskBoardPlanningState(summary: "a plan")
    #expect(TaskBoardPlanApprovalState(planning: planning) == .submitted)
  }

  @Test("whitespace-only summary maps to not approved")
  func whitespaceSummaryIsNotApproved() {
    let planning = TaskBoardPlanningState(summary: "   \n ")
    #expect(TaskBoardPlanApprovalState(planning: planning) == .notApproved)
  }

  @Test("empty planning maps to not approved")
  func emptyPlanningIsNotApproved() {
    #expect(TaskBoardPlanApprovalState(planning: TaskBoardPlanningState()) == .notApproved)
  }

  @Test("badge and accessibility labels are distinct per state")
  func labelsAreDistinct() {
    let labels = [
      TaskBoardPlanApprovalState.notApproved,
      .submitted,
      .approved,
    ].map(\.badgeLabel)
    #expect(Set(labels).count == 3)
    #expect(TaskBoardPlanApprovalState.approved.accessibilityLabel == "Plan approved")
  }
}

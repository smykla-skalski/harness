import Foundation
import HarnessMonitorCore
import XCTest

final class MobileCommandRiskTests: XCTestCase {
  func testCommandKindRiskMapping() {
    XCTAssertEqual(MobileCommandKind.pullRequestMerge.risk, .destructive)
    XCTAssertEqual(MobileCommandKind.pullRequestRerunChecks.risk, .low)
    XCTAssertEqual(MobileCommandKind.refresh.risk, .low)
    let highRiskKinds: [MobileCommandKind] = [
      .acpPermissionDecision, .taskBoardDispatch, .taskBoardPlanApproval, .agentStart,
      .agentStop, .agentPrompt, .pullRequestApprove, .pullRequestLabel,
    ]
    for kind in highRiskKinds {
      XCTAssertEqual(kind.risk, .high, "\(kind.rawValue) should be high risk")
    }
  }

  func testEveryKindHasARiskAndDraftDelegatesToKind() {
    for kind in MobileCommandKind.allCases {
      let draft = MobileCommandDraft(
        kind: kind,
        confirmationText: "confirm",
        target: MobileCommandTarget(stationID: "station", targetRevision: 0)
      )
      XCTAssertEqual(draft.risk, kind.risk, "\(kind.rawValue) draft risk must match kind risk")
    }
  }

  func testAttentionConfirmationMessageCombinesTitleAndSubtitle() {
    let withSubtitle = MobileAttentionItem(
      id: "attention",
      stationID: "station",
      kind: .pullRequest,
      severity: .warning,
      title: "Merge ready",
      subtitle: "2 approvals",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    XCTAssertEqual(withSubtitle.confirmationMessage, "Merge ready\n2 approvals")

    let withoutSubtitle = MobileAttentionItem(
      id: "attention",
      stationID: "station",
      kind: .pullRequest,
      severity: .warning,
      title: "Merge ready",
      subtitle: "",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    XCTAssertEqual(withoutSubtitle.confirmationMessage, "Merge ready")
  }
}

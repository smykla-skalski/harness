import Foundation
import HarnessMonitorCore
import XCTest

final class MobileMirrorModelsTests: XCTestCase {
  func testAttentionSortsCriticalItemsFirst() {
    let now = Date()
    let snapshot = MobileMirrorSnapshot(
      revision: 1,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [],
      attention: [
        MobileAttentionItem(
          id: "warning",
          stationID: "station",
          kind: .pullRequest,
          severity: .warning,
          title: "Warning",
          subtitle: "",
          updatedAt: now
        ),
        MobileAttentionItem(
          id: "critical",
          stationID: "station",
          kind: .acpDecision,
          severity: .critical,
          title: "Critical",
          subtitle: "",
          updatedAt: now.addingTimeInterval(-60)
        ),
      ],
      sessions: [],
      reviews: [],
      commands: []
    )

    XCTAssertEqual(snapshot.sortedAttention.map(\.id), ["critical", "warning"])
  }

  func testAttentionCarriesEncryptedCommandPayload() {
    let item = MobileAttentionItem(
      id: "permission",
      stationID: "station",
      kind: .acpDecision,
      severity: .critical,
      title: "Permission requested",
      subtitle: "Agent wants access.",
      updatedAt: .now,
      commandKind: .acpPermissionDecision,
      target: MobileCommandTarget(
        stationID: "station",
        agentID: "agent",
        targetRevision: 7
      ),
      commandPayload: ["batchID": "batch-1", "decision": "approve_all"]
    )

    XCTAssertEqual(item.commandPayload["batchID"], "batch-1")
    XCTAssertEqual(item.commandPayload["decision"], "approve_all")
  }

  func testDestructiveCommandRequiresAuditReason() {
    let command = MobileCommandRecord(
      id: "command",
      stationID: "station",
      kind: .pullRequestMerge,
      risk: .destructive,
      status: .queued,
      title: "Merge",
      confirmationText: "Merge PR",
      target: MobileCommandTarget(stationID: "station", targetRevision: 4),
      actorDeviceID: "phone",
      createdAt: .now,
      expiresAt: Date().addingTimeInterval(60),
      updatedAt: .now
    )

    XCTAssertThrowsError(try command.validatingForQueue(now: .now)) { error in
      XCTAssertEqual(error as? MobileCommandValidationError, .destructiveCommandMissingAuditReason)
    }
  }

  func testHighRiskCommandRejectsStaleRevision() {
    let command = MobileCommandRecord(
      id: "command",
      stationID: "station",
      kind: .taskBoardPlanApproval,
      risk: .high,
      status: .queued,
      title: "Approve",
      confirmationText: "Approve plan",
      auditReason: "Plan reviewed.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 4),
      actorDeviceID: "phone",
      createdAt: .now,
      expiresAt: Date().addingTimeInterval(60),
      updatedAt: .now
    )

    XCTAssertThrowsError(try command.validatingFreshState(currentRevision: 5)) { error in
      XCTAssertEqual(
        error as? MobileCommandValidationError,
        .staleRevision(expected: 4, actual: 5)
      )
    }
  }
}

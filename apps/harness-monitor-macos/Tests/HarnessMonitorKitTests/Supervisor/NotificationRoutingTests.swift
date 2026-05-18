import UserNotifications
import XCTest

@testable import HarnessMonitorKit

/// Verifies that supervisor notification templates carry a decision id through `userInfo`,
/// that severities map to interruption levels, and that ACP permission requests carry the
/// expected metadata. Tap-action routing lives in `NotificationActionRoutingTests`.
@MainActor
final class NotificationRoutingTests: XCTestCase {
  func test_supervisorRequest_carriesSeverityInterruptionAndDecisionID() async throws {
    let decisionID = "codex-approval:sess-7:appr-42"
    let request = try await HarnessMonitorNotificationRequestFactory.makeSupervisorRequest(
      severity: .needsUser,
      summary: "Stuck agent needs attention",
      decisionID: decisionID
    )
    XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
    XCTAssertEqual(
      request.content.categoryIdentifier,
      HarnessMonitorSupervisorNotificationID.category(for: .needsUser)
    )
    XCTAssertTrue(request.content.body.contains("Stuck agent needs attention"))
    XCTAssertEqual(request.content.threadIdentifier, "io.harnessmonitor.supervisor")
    let decodedID =
      request.content.userInfo[HarnessMonitorSupervisorNotificationID.decisionIDKey] as? String
    XCTAssertEqual(decodedID, decisionID)
  }

  func test_supervisorSeverityMapping_coversAllSeverities() async throws {
    let cases: [(DecisionSeverity, UNNotificationInterruptionLevel)] = [
      (.info, .passive),
      (.warn, .active),
      (.needsUser, .timeSensitive),
      (.critical, .timeSensitive),
    ]
    var identifiers: Set<String> = []
    for (severity, expectedInterruption) in cases {
      let request = try await HarnessMonitorNotificationRequestFactory.makeSupervisorRequest(
        severity: severity,
        summary: "summary",
        decisionID: "decision-\(severity.rawValue)"
      )
      XCTAssertEqual(request.content.interruptionLevel, expectedInterruption, "\(severity)")
      identifiers.insert(request.content.categoryIdentifier)
    }
    XCTAssertEqual(identifiers.count, cases.count, "each severity must map to a unique category")
  }

  func test_supervisorCategoriesRegisterOpenAndAcknowledgeActions() {
    let supervisorCategoryIdentifiers = Set(
      DecisionSeverity.allCases.map(HarnessMonitorSupervisorNotificationID.category(for:))
    )
    let categories = HarnessMonitorNotificationRequestFactory.categories()
      .filter { supervisorCategoryIdentifiers.contains($0.identifier) }
    XCTAssertEqual(categories.count, supervisorCategoryIdentifiers.count)
    for category in categories {
      let actionIDs = Set(category.actions.map(\.identifier))
      XCTAssertTrue(
        actionIDs.contains(HarnessMonitorNotificationActionID.open),
        "\(category.identifier) missing Open action")
      XCTAssertTrue(
        actionIDs.contains(HarnessMonitorNotificationActionID.acknowledge),
        "\(category.identifier) missing Acknowledge action")
    }
  }

  func test_acpPermissionRequest_carriesDecisionIDAndCategory() {
    let decisionID = "codex-approval:sess-7:acp-open"
    let request = HarnessMonitorNotificationRequestFactory.makeAcpPermissionRequest(
      agentName: "Worker Codex",
      decisionID: decisionID
    )

    XCTAssertEqual(
      request.content.categoryIdentifier,
      HarnessMonitorAcpPermissionNotificationID.categoryIdentifier
    )
    XCTAssertEqual(
      request.content.threadIdentifier,
      HarnessMonitorAcpPermissionNotificationID.threadIdentifier
    )
    XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
    XCTAssertTrue(request.content.body.contains("Worker Codex"))
    let decodedID =
      request.content.userInfo[HarnessMonitorSupervisorNotificationID.decisionIDKey] as? String
    XCTAssertEqual(decodedID, decisionID)
  }

  func test_deliverAcpPermissionRequest_schedulesWhenAuthorized() async {
    let center = NotificationRoutingTestCenter()
    let controller = HarnessMonitorUserNotificationController(
      center: center,
      previewSettingsSnapshot: .preview
    )

    let didSchedule = await controller.deliverAcpPermissionRequest(
      AcpPermissionAttentionEvent(
        batchID: "batch-1",
        decisionID: "decision-1",
        agentID: "worker-codex",
        agentName: "Worker Codex",
        requestCount: 2,
        createdAt: "2026-04-28T00:00:01Z"
      )
    )

    XCTAssertTrue(didSchedule)
    let pendingRequests = await center.pendingNotificationRequests()
    XCTAssertEqual(pendingRequests.count, 1)
    XCTAssertEqual(
      pendingRequests.first?.identifier,
      "\(HarnessMonitorAcpPermissionNotificationID.requestPrefix)decision-1"
    )
  }

  func test_deliverAcpPermissionRequest_skipsWhenDenied() async {
    let center = NotificationRoutingTestCenter()
    let controller = HarnessMonitorUserNotificationController(
      center: center,
      previewSettingsSnapshot: AcpPermissionUserNotifications.previewSettingsSnapshot(
        environment: [
          AcpPermissionUserNotifications.previewAuthorizationEnvironmentKey: "denied"
        ]
      )
    )

    let didSchedule = await controller.deliverAcpPermissionRequest(
      AcpPermissionAttentionEvent(
        batchID: "batch-1",
        decisionID: "decision-1",
        agentID: "worker-codex",
        agentName: "Worker Codex",
        requestCount: 2,
        createdAt: "2026-04-28T00:00:01Z"
      )
    )

    XCTAssertFalse(didSchedule)
    let pendingRequests = await center.pendingNotificationRequests()
    XCTAssertTrue(pendingRequests.isEmpty)
  }

  func test_deliverSupervisorDecision_emitsHistoryEvent() async {
    let center = NotificationRoutingTestCenter()
    let recorder = NotificationHistoryEventRecorder()
    let controller = HarnessMonitorUserNotificationController(
      center: center,
      previewSettingsSnapshot: .preview
    )
    controller.attachHistoryEventSink { event in
      Task {
        await recorder.record(event)
      }
    }

    let didSchedule = await controller.deliverSupervisorDecision(
      severity: .needsUser,
      summary: "Review required",
      decisionID: "decision-history"
    )

    XCTAssertTrue(didSchedule)
    for _ in 0..<20 {
      if await recorder.events.count == 1 { break }
      await Task.yield()
    }
    let events = await recorder.events
    XCTAssertEqual(events.count, 1)
    guard case .scheduled(let request, let source, let severity, let actions) = events[0] else {
      return XCTFail("expected scheduled event")
    }
    XCTAssertEqual(request.identifier, "io.harnessmonitor.supervisor.decision.decision-history")
    XCTAssertEqual(source, .supervisorDecision)
    XCTAssertEqual(severity, .attention)
    XCTAssertEqual(actions.count, 2)
  }
}

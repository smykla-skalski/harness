import UserNotifications
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class NotificationActionRoutingTests: XCTestCase {
  func test_tapOpenAction_publishesDecisionRequestedID() async throws {
    let controller = makeNotificationRoutingController()
    let decisionID = "codex-approval:sess-7:appr-open"
    let request = try await makeNotificationRoutingSupervisorRequest(
      decisionID: decisionID,
      severity: .needsUser
    )
    let response = NotificationRoutingResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.open
    )

    XCTAssertNil(controller.decisionRequestedID)
    controller.handleNotificationResponseForTesting(response)
    XCTAssertEqual(controller.decisionRequestedID, decisionID)
  }

  func test_tapAcpPermissionOpenAction_publishesDecisionRequestedID() {
    let controller = makeNotificationRoutingController()
    let decisionID = "codex-approval:sess-7:acp-open"
    let request = HarnessMonitorNotificationRequestFactory.makeAcpPermissionRequest(
      agentName: "Worker Codex",
      decisionID: decisionID
    )
    let response = NotificationRoutingResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.open
    )

    controller.handleNotificationResponseForTesting(response)

    XCTAssertEqual(controller.decisionRequestedID, decisionID)
    XCTAssertEqual(controller.decisionRequestTick, 1)
  }

  func test_tapDefaultAction_publishesDecisionRequestedID() async throws {
    let controller = makeNotificationRoutingController()
    let decisionID = "policy-gap-decision:daemon-outage"
    let request = try await makeNotificationRoutingSupervisorRequest(
      decisionID: decisionID,
      severity: .warn
    )
    let response = NotificationRoutingResponseFactory.make(
      request: request,
      actionIdentifier: UNNotificationDefaultActionIdentifier
    )

    controller.handleNotificationResponseForTesting(response)
    XCTAssertEqual(controller.decisionRequestedID, decisionID)
  }

  func test_tapOpenAction_repeatedSameDecisionIncrementsTickOncePerTap() async throws {
    let controller = makeNotificationRoutingController()
    let decisionID = "codex-approval:sess-7:appr-repeat"
    let request = try await makeNotificationRoutingSupervisorRequest(
      decisionID: decisionID,
      severity: .info
    )
    let response = NotificationRoutingResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.open
    )

    controller.handleNotificationResponseForTesting(response)
    XCTAssertEqual(controller.decisionRequestedID, decisionID)
    XCTAssertEqual(controller.decisionRequestTick, 1)

    controller.handleNotificationResponseForTesting(response)
    XCTAssertEqual(controller.decisionRequestedID, decisionID)
    XCTAssertEqual(controller.decisionRequestTick, 2)
  }

  func test_tapAcknowledgeAction_doesNotOpenWorkspaceWindow() async throws {
    let controller = makeNotificationRoutingController()
    let decisionID = "codex-approval:sess-7:appr-ack"
    let request = try await makeNotificationRoutingSupervisorRequest(
      decisionID: decisionID,
      severity: .warn
    )
    let response = NotificationRoutingResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.acknowledge
    )

    controller.handleNotificationResponseForTesting(response)

    XCTAssertNil(controller.decisionRequestedID)
    XCTAssertEqual(controller.decisionRequestTick, 0)
  }

  func test_tapAcknowledgeAction_dispatchesResolveDismissedOnAttachedStore() async throws {
    let recorder = NotificationRoutingResolveRecorder()
    let controller = makeNotificationRoutingController()
    controller.attachResolveHandler { id, outcome in
      await recorder.record(id: id, outcome: outcome)
    }

    let decisionID = "codex-approval:sess-7:appr-dismiss"
    let request = try await makeNotificationRoutingSupervisorRequest(
      decisionID: decisionID,
      severity: .warn
    )
    let response = NotificationRoutingResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.acknowledge
    )

    controller.handleNotificationResponseForTesting(response)

    for _ in 0..<50 {
      if await recorder.entries.count >= 1 { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let entries = await recorder.entries
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.id, decisionID)
    XCTAssertEqual(
      entries.first?.outcome.chosenActionID,
      HarnessMonitorNotificationActionID.acknowledge
    )
  }

  func test_detachResolveHandlerSuppressesAcknowledgeDispatch() async throws {
    let recorder = NotificationRoutingResolveRecorder()
    let controller = makeNotificationRoutingController()
    controller.attachResolveHandler { id, outcome in
      await recorder.record(id: id, outcome: outcome)
    }
    controller.detachResolveHandler()

    let decisionID = "codex-approval:sess-7:appr-detached"
    let request = try await makeNotificationRoutingSupervisorRequest(
      decisionID: decisionID,
      severity: .warn
    )
    let response = NotificationRoutingResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.acknowledge
    )

    controller.handleNotificationResponseForTesting(response)

    try await Task.sleep(nanoseconds: 50_000_000)
    let entries = await recorder.entries
    XCTAssertTrue(entries.isEmpty)
  }
}

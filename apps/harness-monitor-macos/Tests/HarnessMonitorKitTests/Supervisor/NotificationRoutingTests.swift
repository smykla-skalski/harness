import UserNotifications
import XCTest

@testable import HarnessMonitorKit

/// Verifies that supervisor notification templates carry a decision id through `userInfo`,
/// that tapping the default action (or the explicit "Open" action) surfaces the decision id
/// on `decisionRequestedID`, and that acknowledgement stays on the notification-dismiss path
/// instead of routing into the Decisions window.
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

  func test_tapOpenAction_publishesDecisionRequestedID() async throws {
    let controller = makeController()
    let decisionID = "codex-approval:sess-7:appr-open"
    let request = try await makeSupervisorRequest(
      decisionID: decisionID,
      severity: .needsUser
    )
    let response = TestNotificationResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.open
    )

    XCTAssertNil(controller.decisionRequestedID)
    controller.handleNotificationResponseForTesting(response)
    XCTAssertEqual(controller.decisionRequestedID, decisionID)
  }

  func test_tapDefaultAction_publishesDecisionRequestedID() async throws {
    let controller = makeController()
    let decisionID = "policy-gap-decision:daemon-outage"
    let request = try await makeSupervisorRequest(
      decisionID: decisionID,
      severity: .warn
    )
    let response = TestNotificationResponseFactory.make(
      request: request,
      actionIdentifier: UNNotificationDefaultActionIdentifier
    )

    controller.handleNotificationResponseForTesting(response)
    XCTAssertEqual(controller.decisionRequestedID, decisionID)
  }

  func test_tapOpenAction_repeatedSameDecisionIncrementsTickOncePerTap() async throws {
    let controller = makeController()
    let decisionID = "codex-approval:sess-7:appr-repeat"
    let request = try await makeSupervisorRequest(
      decisionID: decisionID,
      severity: .info
    )
    let response = TestNotificationResponseFactory.make(
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

  func test_tapAcknowledgeAction_doesNotOpenDecisionsWindow() async throws {
    let controller = makeController()
    let decisionID = "codex-approval:sess-7:appr-ack"
    let request = try await makeSupervisorRequest(
      decisionID: decisionID,
      severity: .warn
    )
    let response = TestNotificationResponseFactory.make(
      request: request,
      actionIdentifier: HarnessMonitorNotificationActionID.acknowledge
    )

    controller.handleNotificationResponseForTesting(response)

    // Acknowledge does not open the Decisions window.
    XCTAssertNil(controller.decisionRequestedID)
    XCTAssertEqual(controller.decisionRequestTick, 0)
  }

  func test_tapAcknowledgeAction_dispatchesResolveDismissedOnAttachedStore() async throws {
    let recorder = ResolveRecorder()
    let controller = makeController()
    controller.attachResolveHandler { id, outcome in
      await recorder.record(id: id, outcome: outcome)
    }

    let decisionID = "codex-approval:sess-7:appr-dismiss"
    let request = try await makeSupervisorRequest(
      decisionID: decisionID,
      severity: .warn
    )
    let response = TestNotificationResponseFactory.make(
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

  private func makeSupervisorRequest(
    decisionID: String,
    severity: DecisionSeverity
  ) async throws -> UNNotificationRequest {
    try await HarnessMonitorNotificationRequestFactory.makeSupervisorRequest(
      severity: severity,
      summary: "sample summary",
      decisionID: decisionID
    )
  }

  private func makeController() -> HarnessMonitorUserNotificationController {
    HarnessMonitorUserNotificationController(center: TestNotificationCenter())
  }
}

// MARK: - Test helpers

private actor ResolveRecorder {
  struct Entry: Sendable {
    let id: String
    let outcome: DecisionOutcome
  }

  private(set) var entries: [Entry] = []

  func record(id: String, outcome: DecisionOutcome) {
    entries.append(Entry(id: id, outcome: outcome))
  }
}

private final class TestNotificationCenter: HarnessMonitorUserNotificationCenter,
  @unchecked Sendable
{
  var delegate: UNUserNotificationCenterDelegate?

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    true
  }

  func notificationSettings() async -> UNNotificationSettings {
    fatalError("notificationSettings() should not be called in NotificationRoutingTests")
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }

  func deliveredNotifications() async -> [UNNotification] { [] }

  func notificationCategories() async -> Set<UNNotificationCategory> { [] }

  func add(_ request: UNNotificationRequest) async throws {
    _ = request
  }

  func removeAllPendingNotificationRequests() {}

  func removeAllDeliveredNotifications() {}

  func setBadgeCount(_ newBadgeCount: Int) async throws {
    _ = newBadgeCount
  }

  func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
    _ = categories
  }
}

/// Builds `UNNotificationResponse`s that look delivered without going through the system
/// notification center. Subclassing lets us override `actionIdentifier` and `notification` to
/// drive the controller's response handler.
private enum TestNotificationResponseFactory {
  static func make(
    request: UNNotificationRequest,
    actionIdentifier: String
  ) -> UNNotificationResponse {
    StubResponse(request: request, overrideActionIdentifier: actionIdentifier)
  }

  private final class StubNotification: UNNotification {
    private let requestValue: UNNotificationRequest

    init(request: UNNotificationRequest) {
      self.requestValue = request
      super.init(coder: Self.sharedDummyCoder())!
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var request: UNNotificationRequest { requestValue }
    override var date: Date { Date() }

    private static func sharedDummyCoder() -> NSCoder {
      let archiver = NSKeyedArchiver(requiringSecureCoding: false)
      archiver.encode(Date(), forKey: "date")
      archiver.finishEncoding()
      // swiftlint:disable:next force_try
      let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
      unarchiver.requiresSecureCoding = false
      return unarchiver
    }
  }

  private final class StubResponse: UNNotificationResponse {
    private let overrideActionIdentifier: String
    private let notificationValue: StubNotification

    init(request: UNNotificationRequest, overrideActionIdentifier: String) {
      self.overrideActionIdentifier = overrideActionIdentifier
      self.notificationValue = StubNotification(request: request)
      super.init(coder: Self.sharedDummyCoder())!
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var actionIdentifier: String { overrideActionIdentifier }
    override var notification: UNNotification { notificationValue }

    private static func sharedDummyCoder() -> NSCoder {
      let archiver = NSKeyedArchiver(requiringSecureCoding: false)
      archiver.encode("", forKey: "actionIdentifier")
      archiver.finishEncoding()
      // swiftlint:disable:next force_try
      let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
      unarchiver.requiresSecureCoding = false
      return unarchiver
    }
  }
}

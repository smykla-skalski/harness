import Foundation
import Testing
import UserNotifications

@testable import HarnessMonitor
@testable import HarnessMonitorKit

@MainActor
struct AcpPermissionAttentionStateTests {
  @Test("reconcile schedules at most one ACP notification while delivery is in flight")
  func reconcileDoesNotDuplicateInFlightNotifications() async {
    let center = AppTestNotificationCenter()
    let controller = HarnessMonitorUserNotificationController(
      center: center,
      previewSettingsSnapshot: .preview
    )
    let application = AppTestWindowApplication(
      keyWindowIdentifier: nil,
      isActive: false,
      isHidden: true,
      windowStates: []
    )
    let state = AcpPermissionAttentionState(
      keyWindowObserver: KeyWindowObserver(application: application),
      notifications: controller
    )
    let store = HarnessMonitorStore(daemonController: PreviewDaemonController(mode: .empty))
    store.selectedSessionID = "sess-acp-attention"
    store.applyAcpAgent(
      makeWorkerSnapshot(
        acpID: "acp-1",
        sessionID: "sess-acp-attention",
        pendingBatches: [
          AcpPermissionBatch(
            batchId: "batch-1",
            acpId: "acp-1",
            sessionId: "sess-acp-attention",
            requests: [
              AcpPermissionItem(
                requestId: "batch-1-request",
                sessionId: "sess-acp-attention",
                toolCall: .object([
                  "kind": .string("write"),
                  "path": .string("README.md"),
                ]),
                options: [.string("allow"), .string("deny")]
              )
            ],
            createdAt: "2026-04-28T00:00:01Z"
          )
        ]
      )
    )
    store.supervisorOpenDecisions = [
      makeDecision(
        id: "decision-old",
        agentID: "worker-codex",
        createdAt: 10
      )
    ]
    #expect(store.acpPermissionAttentionEvents.count == 1)
    #expect(
      store.acpPermissionAttentionEvents.first?.decisionID == "decision-old"
    )

    state.reconcile(store: store)
    state.reconcile(store: store)
    await waitForNotificationDelivery(in: center)

    let pendingRequests = await center.pendingNotificationRequests()
    #expect(pendingRequests.count == 1)
    #expect(controller.lastResult == "Scheduled ACP permission batch-1.")
  }

  private func makeWorkerSnapshot(
    acpID: String,
    sessionID: String,
    pendingBatches: [AcpPermissionBatch]
  ) -> AcpAgentSnapshot {
    AcpAgentSnapshot(
      acpId: acpID,
      sessionId: sessionID,
      agentId: "worker-codex",
      displayName: "Worker Codex",
      status: .active,
      pid: 12_345,
      pgid: 12_345,
      projectDir: "/tmp/project",
      pendingPermissions: pendingBatches.reduce(0) { $0 + $1.requests.count },
      permissionQueueDepth: pendingBatches.count,
      pendingPermissionBatches: pendingBatches,
      terminalCount: 0,
      createdAt: "2026-04-28T00:00:00Z",
      updatedAt: "2026-04-28T00:00:00Z"
    )
  }

  private func makeDecision(
    id: String,
    agentID: String,
    createdAt: TimeInterval
  ) -> Decision {
    let decision = Decision(
      id: id,
      severity: .warn,
      ruleID: "stuck-agent",
      sessionID: "sess-acp-attention",
      agentID: agentID,
      taskID: nil,
      summary: "Decision \(id)",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    decision.createdAt = Date(timeIntervalSince1970: createdAt)
    return decision
  }

  private func waitForNotificationDelivery(
    in center: AppTestNotificationCenter,
    attempts: Int = 20
  ) async {
    for _ in 0..<attempts {
      if await center.pendingNotificationRequests().count == 1 {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

}

@MainActor
private final class AppTestWindowApplication: KeyWindowObservableApplication {
  var keyWindowIdentifier: String?
  var isActive: Bool
  var isHidden: Bool
  var windowStates: [KeyWindowState]

  init(
    keyWindowIdentifier: String?,
    isActive: Bool,
    isHidden: Bool,
    windowStates: [KeyWindowState]
  ) {
    self.keyWindowIdentifier = keyWindowIdentifier
    self.isActive = isActive
    self.isHidden = isHidden
    self.windowStates = windowStates
  }
}

private final class AppTestNotificationCenter: HarnessMonitorUserNotificationCenter, @unchecked Sendable {
  var delegate: UNUserNotificationCenterDelegate?

  private var pendingRequests: [UNNotificationRequest] = []
  private var categories: Set<UNNotificationCategory> = []

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    _ = options
    return true
  }

  func notificationSettings() async -> UNNotificationSettings {
    fatalError("unused in preview-backed tests")
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] {
    pendingRequests
  }

  func deliveredNotifications() async -> [UNNotification] {
    []
  }

  func notificationCategories() async -> Set<UNNotificationCategory> {
    categories
  }

  func add(_ request: UNNotificationRequest) async throws {
    pendingRequests.append(request)
  }

  func removeAllPendingNotificationRequests() {
    pendingRequests.removeAll()
  }

  func removeAllDeliveredNotifications() {}

  func setBadgeCount(_ newBadgeCount: Int) async throws {
    _ = newBadgeCount
  }

  func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
    self.categories = categories
  }
}

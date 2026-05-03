import XCTest

@testable import HarnessMonitorKit

@MainActor
final class DecisionActionHandlerSupervisorCustomTests: XCTestCase {
  func test_restartDaemonCustomActionStopsAndStartsDaemon() async throws {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    let decisions = try DecisionStore.makeInMemory()
    let handler = StoreDecisionActionHandler(store: store, decisions: decisions)
    try await decisions.insert(
      draft(
        id: "daemon-restart",
        action: SuggestedAction(
          id: "restart-daemon",
          title: "Restart daemon",
          kind: .custom,
          payloadJSON: #"{"mode":"restartDaemon"}"#
        )
      )
    )

    await handler.resolve(
      decisionID: "daemon-restart",
      outcome: DecisionOutcome(chosenActionID: "restart-daemon", note: nil)
    )

    let stopCallCount = await daemon.recordedStopDaemonCallCount()
    let warmUpCallCount = await daemon.recordedWarmUpCallCount()
    XCTAssertEqual(stopCallCount, 1)
    XCTAssertEqual(warmUpCallCount, 1)
    XCTAssertEqual(store.connectionState, .online)
    let resolved = try await decisions.decision(id: "daemon-restart")
    XCTAssertEqual(resolved?.statusRaw, "resolved")
  }

  func test_openDaemonLogsCustomActionUsesResolvedDaemonLogURL() async throws {
    let daemon = RecordingDaemonController()
    let fileViewer = RecordingSupervisorActionFileViewer()
    let store = HarnessMonitorStore(daemonController: daemon, fileViewer: fileViewer)
    await store.refreshDaemonStatus()
    let decisions = try DecisionStore.makeInMemory()
    let handler = StoreDecisionActionHandler(store: store, decisions: decisions)
    try await decisions.insert(
      draft(
        id: "daemon-logs",
        action: SuggestedAction(
          id: "open-daemon-logs",
          title: "Open daemon logs",
          kind: .custom,
          payloadJSON: #"{"mode":"openDaemonLogs"}"#
        )
      )
    )

    await handler.resolve(
      decisionID: "daemon-logs",
      outcome: DecisionOutcome(chosenActionID: "open-daemon-logs", note: nil)
    )

    XCTAssertEqual(fileViewer.openedURLs.map(\.path), ["/tmp/harness/daemon/events.jsonl"])
    let resolved = try await decisions.decision(id: "daemon-logs")
    XCTAssertEqual(resolved?.statusRaw, "resolved")
  }

  private func draft(id: String, action: SuggestedAction) throws -> DecisionDraft {
    let data = try JSONEncoder().encode([action])
    let suggestedActionsJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
    return DecisionDraft(
      id: id,
      severity: .critical,
      ruleID: "daemon-disconnect",
      sessionID: nil,
      agentID: nil,
      taskID: nil,
      summary: "Daemon disconnected",
      contextJSON: "{}",
      suggestedActionsJSON: suggestedActionsJSON
    )
  }
}

@MainActor
private final class RecordingSupervisorActionFileViewer: FileViewerActivating {
  private(set) var openedURLs: [URL] = []
  private(set) var revealedURLs: [URL] = []

  func reveal(itemsAt urls: [URL]) {
    revealedURLs.append(contentsOf: urls)
  }

  func open(itemAt url: URL) {
    openedURLs.append(url)
  }
}

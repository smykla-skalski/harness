import Foundation
import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
final class SessionDecisionCommandFactoryTests: XCTestCase {
  func testCommandStateReflectsSelectedVisibleAndReopenBatch() {
    let store = HarnessMonitorStore.fixture()
    let state = SessionWindowStateCache(sessionID: "s1")

    let empty = makeCommand(store: store, state: state, visibleDecisions: [])
    XCTAssertFalse(empty.canDismissSelected)
    XCTAssertFalse(empty.canDismissVisible)
    XCTAssertFalse(empty.canReopenBatch)

    state.sidebarSelection.toggleDecision("d-selected")
    state.decisionBulkActions.recordDismissedBatch(["d-dismissed"], undoManager: nil)
    let command = makeCommand(
      store: store,
      state: state,
      visibleDecisions: [makeDecision("d-visible-a"), makeDecision("d-visible-b")]
    )

    XCTAssertEqual(command.sessionID, "s1")
    XCTAssertTrue(command.canDismissSelected)
    XCTAssertTrue(command.canDismissVisible)
    XCTAssertTrue(command.canReopenBatch)
  }

  func testDismissSelectedRecordsUndoableBatch() async {
    let store = HarnessMonitorStore.fixture()
    let state = SessionWindowStateCache(sessionID: "s1")
    let undoManager = UndoManager()
    state.sidebarSelection.toggleDecision("d-selected")

    let command = makeCommand(store: store, state: state, undoManager: undoManager)
    command.dismissSelected()
    await allowCommandTaskToRun()

    XCTAssertEqual(state.decisionBulkActions.lastDismissedBatch, ["d-selected"])
    XCTAssertTrue(undoManager.canUndo)
    undoManager.undo()
    XCTAssertEqual(state.decisionBulkActions.reopenRequestedBatch, ["d-selected"])
  }

  func testDismissVisibleRecordsFilteredVisibleDecisionIDs() async {
    let store = HarnessMonitorStore.fixture()
    let state = SessionWindowStateCache(sessionID: "s1")
    let visible = [makeDecision("d-visible-a"), makeDecision("d-visible-b")]

    let command = makeCommand(store: store, state: state, visibleDecisions: visible)
    command.dismissVisible()
    await allowCommandTaskToRun()

    XCTAssertEqual(state.decisionBulkActions.lastDismissedBatch, ["d-visible-a", "d-visible-b"])
  }

  func testDismissVisibleCopyIsSharedBySidebarAndSettings() throws {
    XCTAssertEqual(
      SessionDecisionBulkActionCopy.dismissVisibleHelp,
      "Dismiss All Visible applies to decisions matching the current filter and search."
    )

    let sidebarSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarDecisionSection.swift"
    )
    let settingsSource = try previewableSourceFile(
      named: "Views/Settings/SettingsBannersSection.swift"
    )

    XCTAssertTrue(sidebarSource.contains("SessionDecisionBulkActionCopy.dismissVisibleHelp"))
    XCTAssertTrue(settingsSource.contains("SessionDecisionBulkActionCopy.dismissVisibleHelp"))
    XCTAssertTrue(
      settingsSource.contains("harness.settings.decisions.dismiss-visible-help")
    )
  }

  func testReopenBatchUsesDecisionStoreMutation() async throws {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
    let decisionID = "d-command-reopen"
    try await store.insertDecisionForTesting(.fixture(id: decisionID, sessionID: "s1"))
    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    try await decisionStore.dismiss(id: decisionID)
    let dismissed = try await decisionStore.decision(id: decisionID)
    XCTAssertEqual(dismissed?.statusRaw, "dismissed")

    let state = SessionWindowStateCache(sessionID: "s1")
    state.decisionBulkActions.recordDismissedBatch([decisionID], undoManager: nil)
    let command = makeCommand(store: store, state: state)
    command.reopenBatch()
    await allowCommandTaskToRun()

    let reopened = try await decisionStore.decision(id: decisionID)
    XCTAssertEqual(reopened?.statusRaw, "open")
  }

  private func makeCommand(
    store: HarnessMonitorStore,
    state: SessionWindowStateCache,
    visibleDecisions: [Decision] = [],
    undoManager: UndoManager? = nil
  ) -> SessionDecisionCommand {
    SessionDecisionCommandFactory.make(
      store: store,
      state: state,
      visibleDecisions: visibleDecisions,
      undoManager: undoManager
    )
  }

  private func makeDecision(_ id: String) -> Decision {
    Decision(
      id: id,
      severity: .needsUser,
      ruleID: "stuck-agent",
      sessionID: "s1",
      agentID: "a1",
      taskID: nil,
      summary: "Agent stalled",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
  }

  private func allowCommandTaskToRun() async {
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(50))
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}

import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session window flow contracts")
struct SessionWindowFlowTests {
  @Test("Session window token encodes the session identity")
  func sessionWindowTokenEncodingRoundTrips() throws {
    let token = SessionWindowToken(sessionID: "sess-alpha")
    let data = try JSONEncoder().encode(token)
    let decoded = try JSONDecoder().decode(SessionWindowToken.self, from: data)

    #expect(decoded == token)
    #expect(decoded.sessionID == "sess-alpha")
  }

  @Test("Session windows route through the main value-routed scene")
  func sessionWindowsRouteThroughMainSceneID() {
    #expect(HarnessMonitorWindowID.main == "main")
    #expect(HarnessMonitorWindowID.sessionWindow("sess-alpha") == "session-sess-alpha")
  }

  @Test("Current schema includes session window restoration state")
  func currentSchemaIncludesSessionWindowRestorationState() {
    #expect(HarnessMonitorCurrentSchema.versionString == "9.0.0")
    #expect(
      HarnessMonitorSchemaV9.models.contains {
        String(describing: $0) == "CachedSessionWindowState"
      }
    )
  }

  @Test("Session window tabbing preference defaults to system")
  func sessionWindowTabbingPreferenceDefaultsToSystem() {
    #expect(SessionWindowTabbingPreference.defaultValue == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: nil) == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "system") == .system)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "always") == .always)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "never") == .never)
    #expect(SessionWindowTabbingPreference.resolved(rawValue: "unknown") == .system)
    #expect(
      SessionWindowTabbingPreference.storageKey == "harness.monitor.session-window.tabbing"
    )
  }

  @Test("Session routes expose stable sidebar order")
  func sessionRoutesExposeStableSidebarOrder() {
    #expect(
      SessionWindowRoute.allCases.map(\.rawValue)
        == ["overview", "agents", "tasks", "decisions", "timeline", "terminal"]
    )
    #expect(SessionWindowRoute.terminal.title == "Terminal/Runs")
    #expect(SessionWindowRoute.decisions.systemImage == "exclamationmark.bubble")
  }

  @MainActor
  @Test("Session window state cache records session-scoped deep selections")
  func sessionWindowStateCacheRecordsDeepSelections() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    #expect(state.selection == .route(.overview))
    state.selectRoute(.timeline)
    state.selectDecision("decision-1")
    state.selectAgent("agent-1")
    state.selectTask("task-1")

    #expect(state.selection == .task(sessionID: "sess-alpha", taskID: "task-1"))
    #expect(state.selection.taskID == "task-1")
    #expect(
      state.navigationHistory.backStack == [
        .route(.overview),
        .route(.timeline),
        .decision(sessionID: "sess-alpha", decisionID: "decision-1"),
        .agent(sessionID: "sess-alpha", agentID: "agent-1"),
      ]
    )

    state.selectTask("task-1")
    #expect(state.navigationHistory.backStack.count == 4)
  }

  @MainActor
  @Test("Session window cache preserves create drafts and section selections")
  func sessionWindowCachePreservesCreateDraftsAndSectionSelections() throws {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    state.selectAgent("agent-1")
    state.selectCreate(.agent)
    var draft = try #require(state.selection.createDraft)
    draft.title = "Review worker"
    state.updateCreateDraft(draft)
    state.selectTask("task-1")
    state.selectCreate(.agent)

    #expect(state.sectionState.agentID == "agent-1")
    #expect(state.sectionState.taskID == "task-1")
    #expect(state.selection.createDraft?.title == "Review worker")
    #expect(state.selection.createDraft?.sessionID == "sess-alpha")
  }

  @MainActor
  @Test("Session sidebar ordering registers undoable agent moves")
  func sessionSidebarOrderingRegistersUndoableAgentMoves() {
    let ordering = SessionSidebarOrderingState()
    ordering.agentIDs = ["agent-a", "agent-b", "agent-c"]
    let undoManager = UndoManager()

    ordering.moveAgent("agent-c", before: "agent-a", undoManager: undoManager)

    #expect(ordering.agentIDs == ["agent-c", "agent-a", "agent-b"])
    #expect(undoManager.canUndo)
    undoManager.undo()
    #expect(ordering.agentIDs == ["agent-a", "agent-b", "agent-c"])
  }

  @MainActor
  @Test("Session sidebar decision multi-select prunes to visible rows")
  func sessionSidebarDecisionMultiSelectPrunesToVisibleRows() {
    let selection = SessionSidebarSelectionState()

    selection.toggleDecisionMultiSelect()
    selection.toggleDecision("decision-a")
    selection.toggleDecision("decision-b")
    selection.pruneDecisionSelection(to: ["decision-b", "decision-c"])

    #expect(selection.isDecisionMultiSelectEnabled)
    #expect(selection.selectedDecisionIDs == ["decision-b"])
    selection.toggleDecisionMultiSelect()
    #expect(selection.selectedDecisionIDs.isEmpty)
  }

  @MainActor
  @Test("Session decision filters match query and severity")
  func sessionDecisionFiltersMatchQueryAndSeverity() {
    let filters = SessionDecisionFilterState()
    let decision = Decision(
      id: "decision-a",
      severity: .critical,
      ruleID: "stuck-agent",
      sessionID: "sess-alpha",
      agentID: "agent-a",
      taskID: "task-a",
      summary: "Agent stopped responding",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )

    filters.query = "responding"
    #expect(filters.matches(decision))
    filters.severities = [.warn]
    #expect(!filters.matches(decision))
    filters.severities = [.critical]
    #expect(filters.matches(decision))
  }

  @MainActor
  @Test("Session decision bulk actions register undo reopen requests")
  func sessionDecisionBulkActionsRegisterUndoReopenRequests() {
    let bulkActions = SessionDecisionBulkActionState()
    let undoManager = UndoManager()

    bulkActions.recordDismissedBatch(["decision-a", "decision-b"], undoManager: undoManager)

    #expect(bulkActions.lastDismissedBatch == ["decision-a", "decision-b"])
    #expect(undoManager.canUndo)
    undoManager.undo()
    #expect(bulkActions.reopenRequestedBatch == ["decision-a", "decision-b"])
  }

  @Test("Launch behavior defaults to restoring session windows")
  func launchBehaviorDefaultsToRestoringSessionWindows() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    #expect(
      HarnessMonitorLaunchBehavior.read(userDefaults: defaults.userDefaults)
        == .restoreSessionWindows
    )
    defaults.userDefaults.set(
      HarnessMonitorLaunchBehavior.alwaysOpenRecent.rawValue,
      forKey: HarnessMonitorLaunchBehavior.storageKey
    )
    #expect(
      HarnessMonitorLaunchBehavior.read(userDefaults: defaults.userDefaults)
        == .alwaysOpenRecent
    )
    defaults.userDefaults.set("legacy-garbage", forKey: HarnessMonitorLaunchBehavior.storageKey)
    #expect(
      HarnessMonitorLaunchBehavior.read(userDefaults: defaults.userDefaults)
        == .restoreSessionWindows
    )
  }

  @Test("Open Recent closes after picking a session by default")
  func openRecentCloseAfterPickDefaultsOnAndPersistsOff() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    #expect(OpenRecentCloseAfterPickDefaults.read(userDefaults: defaults.userDefaults))
    defaults.userDefaults.set(
      false,
      forKey: OpenRecentCloseAfterPickDefaults.storageKey
    )
    #expect(!OpenRecentCloseAfterPickDefaults.read(userDefaults: defaults.userDefaults))
    #expect(
      OpenRecentCloseAfterPickDefaults.storageKey
        == "harness.monitor.open-recent.close-after-pick"
    )
  }

  @Test("Open Recent close-after-pick dismisses only the current welcome window")
  func openRecentCloseAfterPickUsesCurrentWindowDismiss() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(source.contains("@Environment(\\.dismiss)"))
    #expect(source.contains("dismiss()"))
    #expect(!source.contains("@Environment(\\.dismissWindow)"))
    #expect(!source.contains("dismissWindow(id: HarnessMonitorWindowID.main)"))
  }

  @Test("Sidebar density keeps strict default and maps legacy values")
  func sidebarDensityResolvesStrictDefaultAndLegacyValues() {
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.defaultMode == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: nil) == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "strict") == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "dense") == .dense)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "concise") == .strict)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "detailed") == .dense)
    #expect(HarnessMonitorSidebarSessionRowDisplayMode.resolved(rawValue: "unknown") == .strict)
  }

  private func isolatedDefaults() throws -> (userDefaults: UserDefaults, suiteName: String) {
    let suiteName = "SessionWindowFlowTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return (userDefaults, suiteName)
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

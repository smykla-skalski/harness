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
  @Test("Session sidebar keyboard selection requests agent composer focus only for agents")
  func sessionSidebarKeyboardSelectionRequestsAgentComposerFocusOnlyForAgents() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")

    state.selectFromSidebar(.route(.timeline))
    #expect(state.selectionSource == .keyboard)
    #expect(state.agentComposerFocusRequestID == 0)

    state.selectFromSidebar(.agent(sessionID: "sess-alpha", agentID: "agent-a"))
    #expect(state.selection == .agent(sessionID: "sess-alpha", agentID: "agent-a"))
    #expect(state.selectionSource == .keyboard)
    #expect(state.agentComposerFocusRequestID == 1)

    state.selectFromSidebar(.task(sessionID: "sess-alpha", taskID: "task-a"))
    #expect(state.agentComposerFocusRequestID == 1)
  }

  @MainActor
  @Test("Session sidebar pointer selection suppresses agent composer focus")
  func sessionSidebarPointerSelectionSuppressesAgentComposerFocus() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")
    let pointerSelection = SessionSelection.agent(sessionID: "sess-alpha", agentID: "agent-a")

    state.markPointerSelectionIntent(for: pointerSelection)
    state.selectFromSidebar(pointerSelection)

    #expect(state.selection == pointerSelection)
    #expect(state.selectionSource == .pointer)
    #expect(state.agentComposerFocusRequestID == 0)

    state.selectAgent("agent-b")
    #expect(state.selection == .agent(sessionID: "sess-alpha", agentID: "agent-b"))
    #expect(state.selectionSource == .programmatic)
    #expect(state.agentComposerFocusRequestID == 0)
  }

  @MainActor
  @Test("Session window navigation history is isolated per window cache")
  func sessionWindowNavigationHistoryIsIsolatedPerWindowCache() {
    let alpha = SessionWindowStateCache(sessionID: "sess-alpha")
    let beta = SessionWindowStateCache(sessionID: "sess-beta")

    alpha.selectRoute(.timeline)
    alpha.selectAgent("agent-alpha")
    beta.selectRoute(.decisions)

    alpha.navigateBack()

    #expect(alpha.selection == .route(.timeline))
    #expect(beta.selection == .route(.decisions))
    #expect(beta.navigationHistory.backStack == [.route(.overview)])

    beta.navigateBack()

    #expect(alpha.selection == .route(.timeline))
    #expect(beta.selection == .route(.overview))
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
  @Test("Session decision filters match query severity and scope")
  func sessionDecisionFiltersMatchQuerySeverityAndScope() {
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
    filters.scope = .ruleID
    #expect(!filters.matches(decision))
    filters.query = "stuck-agent"
    #expect(filters.matches(decision))
    filters.scope = .agent
    #expect(!filters.matches(decision))
    filters.query = "agent-a"
    #expect(filters.matches(decision))
    filters.severities = [.warn]
    #expect(!filters.matches(decision))
    filters.severities = [.critical]
    #expect(filters.matches(decision))
    filters.clear()
    #expect(filters.scope == .summary)
    #expect(filters.matches(decision))
  }

  @Test("Session decision filters use toggles and live region includes visible count")
  func sessionDecisionFiltersUseTogglesAndLiveRegionIncludesVisibleCount() throws {
    let sidebarSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar.swift")
    let filterSource = try previewableSourceFile(named: "Views/Sessions/SessionSidebar+Filtering.swift")
    let decisionSectionSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarDecisionSection.swift"
    )

    #expect(filterSource.contains("Toggle(severity.rawValue.capitalized"))
    #expect(filterSource.contains("private func severityBinding"))
    #expect(sidebarSource.contains(".accessibilityValue(decisionSelectionAccessibilityValue)"))
    #expect(sidebarSource.contains(#""\(count) of \(decisions.count) decisions selected""#))
    #expect(sidebarSource.contains("visibleCount: decisions.count"))
    #expect(decisionSectionSource.contains(#""\(count) of \(visibleCount) decisions selected""#))
  }

  @MainActor
  @Test("Session window decision visibility distinguishes visible hidden and missing states")
  func sessionWindowDecisionVisibilityDistinguishesStates() {
    let state = SessionWindowStateCache(sessionID: "sess-alpha")
    state.selectDecision("decision-visible")

    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-visible", "decision-hidden"],
        visibleDecisionIDs: ["decision-visible"]
      ) == .visible
    )
    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-visible", "decision-hidden"],
        visibleDecisionIDs: ["decision-hidden"]
      ) == .hidden
    )
    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-hidden"],
        visibleDecisionIDs: ["decision-hidden"]
      ) == .missing
    )

    state.selectRoute(.overview)
    #expect(
      state.selectedDecisionVisibility(
        allDecisionIDs: ["decision-visible"],
        visibleDecisionIDs: ["decision-visible"]
      ) == .none
    )
  }

  @Test("Session inspector auto-collapse preserves preferred visibility")
  func sessionInspectorAutoCollapsePreservesPreferredVisibility() {
    #expect(!SessionInspectorVisibilityPolicy.allowsInspector(width: 1099))
    #expect(SessionInspectorVisibilityPolicy.allowsInspector(width: 1100))
    #expect(
      !SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: true,
        canPresent: false
      )
    )
    #expect(
      SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: true,
        canPresent: true
      )
    )
    #expect(
      !SessionInspectorVisibilityPolicy.resolvedVisible(
        preferredVisible: false,
        canPresent: true
      )
    )
  }

  @Test("Session window stores inspector preference separately from actual visibility")
  func sessionWindowStoresInspectorPreferenceSeparatelyFromActualVisibility() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let inspectorPolicySource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Inspector.swift"
    )
    let columnsSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView+Columns.swift")
    let inspectorSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowInspector.swift")

    #expect(viewSource.contains("@SceneStorage(\"session.inspector.visible\")"))
    #expect(viewSource.contains("@SceneStorage(\"session.inspector.preferred\")"))
    #expect(inspectorPolicySource.contains("preferredVisible: preferredBinding.wrappedValue"))
    #expect(columnsSource.contains("preferredVisible: $inspectorPreferred"))
    #expect(inspectorSource.contains("@Binding var preferredVisible"))
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

  @MainActor
  @Test("Session decision bulk actions expose expiring undo toast")
  func sessionDecisionBulkActionsExposeExpiringUndoToast() throws {
    let bulkActions = SessionDecisionBulkActionState()
    let now = Date(timeIntervalSinceReferenceDate: 100)

    bulkActions.recordDismissedBatch(["decision-a", "decision-b"], undoManager: nil, now: now)

    let toast = try #require(bulkActions.undoToast)
    #expect(toast.count == 2)
    #expect(toast.expiresAt == now.addingTimeInterval(8))
    bulkActions.clearExpiredUndoToast(now: now.addingTimeInterval(7.9))
    #expect(bulkActions.undoToast != nil)
    bulkActions.clearExpiredUndoToast(now: now.addingTimeInterval(8))
    #expect(bulkActions.undoToast == nil)

    bulkActions.recordDismissedBatch(["decision-c"], undoManager: nil, now: now)
    bulkActions.requestUndoToastReopen()

    #expect(bulkActions.reopenRequestedBatch == ["decision-c"])
    #expect(bulkActions.undoToast == nil)
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

  @Test("Open Recent toggle uses the canonical close-after-pick copy")
  func openRecentCloseAfterPickUsesCanonicalVisibleCopy() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(source.contains("Toggle(\"Close Open Recent after picking a session\", isOn: $closeAfterPick)"))
    #expect(!source.contains("Toggle(\"Close after opening a session\", isOn: $closeAfterPick)"))
  }

  @MainActor
  @Test("Open Recent motion policy disables animation for reduce motion")
  func openRecentCloseAfterPickMotionPolicyRespectsReduceMotion() {
    #expect(OpenRecentCloseAfterPickMotionPolicy.animation(reduceMotion: true) == nil)
    #expect(OpenRecentCloseAfterPickMotionPolicy.animation(reduceMotion: false) != nil)
    #expect(OpenRecentCloseAfterPickMotionPolicy.dismissDelay(reduceMotion: true) == .zero)
    #expect(
      OpenRecentCloseAfterPickMotionPolicy.dismissDelay(reduceMotion: false)
        == .milliseconds(160)
    )
  }

  @Test("Open Recent close-after-pick uses native SwiftUI scene routing")
  func openRecentCloseAfterPickUsesCurrentWindowDismiss() throws {
    let source = try previewableSourceFile(named: "Views/Sessions/OpenRecentView.swift")

    #expect(!source.contains("import AppKit"))
    #expect(source.contains("@Environment(\\.dismiss)"))
    #expect(source.contains("@Environment(\\.openWindow)"))
    #expect(source.contains("openWindow("))
    #expect(source.contains("await Task.yield()"))
    #expect(source.contains("dismiss()"))
    #expect(!source.contains("OpenRecentSessionLaunchHandoff"))
    #expect(!source.contains("OpenRecentSourceWindowResolver"))
    #expect(!source.contains("NSApplication"))
    #expect(!source.contains("NSWindow"))
    #expect(!source.contains("requestUserAttention"))
    #expect(!source.contains("makeKeyAndOrderFront"))
    #expect(!source.contains("sourceWindow.close()"))
    #expect(!source.contains("@Environment(\\.dismissWindow)"))
    #expect(!source.contains("dismissWindow(id: HarnessMonitorWindowID.main)"))
  }

  @Test("Session tabs route through SwiftUI commands plus the tabbing accessor")
  func sessionTabsUseSwiftUISceneCommands() throws {
    let appSource = try harnessSourceFile(named: "App/HarnessMonitorApp.swift")
    let rootSource = try harnessSourceFile(named: "App/SessionWindowRootView.swift")
    let commandsSource = try harnessSourceFile(named: "Commands/WindowMenuCommands.swift")
    let tabbingAccessorPath = harnessSourceURL(named: "App/SessionWindowTabbing.swift").path
    let tabbingSource = try harnessSourceFile(named: "App/SessionWindowTabbing.swift")

    #expect(FileManager.default.fileExists(atPath: tabbingAccessorPath))
    #expect(appSource.contains("WindowGroup("))
    #expect(appSource.contains("for: SessionWindowToken.self"))
    #expect(appSource.contains("SessionWindowTabbing(isSessionWindow: false)"))
    #expect(commandsSource.contains("@Environment(\\.openWindow)"))
    #expect(commandsSource.contains("openWindow("))
    #expect(rootSource.contains("SessionWindowTabbing(isSessionWindow: true)"))
    #expect(tabbingSource.contains("tabbingIdentifier"))
    #expect(!commandsSource.contains("NSWindow"))
    #expect(!commandsSource.contains("tabbingIdentifier"))
  }

  @Test("Session inspector divider remains SwiftUI native")
  func sessionInspectorDividerRemainsSwiftUINative() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let dividerSource = try previewableSourceFile(named: "Views/Sessions/SessionInspectorDivider.swift")

    #expect(!viewSource.contains("import AppKit"))
    #expect(!dividerSource.contains("import AppKit"))
    #expect(dividerSource.contains("DragGesture("))
    #expect(!dividerSource.contains("NSCursor"))
  }

  @Test("Session window owns the content-detail split UX")
  func sessionWindowOwnsTheContentDetailSplitUX() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let splitSource = try previewableSourceFile(
      named: "Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(viewSource.contains("@SceneStorage(\"session.content-detail.width\")"))
    #expect(viewSource.contains("sessionSurface"))
    #expect(
      columnsSource.contains("SessionContentDetailSplitView(contentWidth: $contentColumnWidth)")
    )
    #expect(columnsSource.contains(".navigationSplitViewStyle(.prominentDetail)"))
    #expect(splitSource.contains("NSCursor.resizeLeftRight"))
    #expect(splitSource.contains("@State private var liveContentWidth"))
    #expect(splitSource.contains("_liveContentWidth = State(wrappedValue: contentWidth.wrappedValue)"))
    #expect(splitSource.contains(".accessibilityAdjustableAction"))
    #expect(splitSource.contains(".focusEffectDisabled()"))
    #expect(splitSource.contains(".focusable(interactions: .activate)"))
    #expect(splitSource.contains("if !isDragging {"))
    #expect(splitSource.contains(".onMoveCommand"))
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

  private func harnessSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessSourceURL(named relativePath: String) -> URL {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    return repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor")
      .appendingPathComponent(relativePath)
  }
}

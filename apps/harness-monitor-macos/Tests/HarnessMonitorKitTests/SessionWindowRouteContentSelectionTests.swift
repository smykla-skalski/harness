import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Session window route content selection")
struct SessionWindowRouteContentSelectionTests {
  @Test("Session sidebar routes include the session decisions queue")
  func sessionSidebarRoutesIncludeSessionDecisionsQueue() throws {
    let sidebar = try sourceFile(named: "SessionSidebar.swift")

    #expect(
      sidebar.contains(
        "ForEach([SessionWindowRoute.overview, .timeline, .agents, .decisions])"
      )
    )
    #expect(
      sidebar.contains(
        "routeSection\n      agentsSection\n      decisionsSection\n      tasksSection"
      )
    )
    #expect(!sidebar.contains("Text(\"Routes\")"))
    #expect(!sidebar.contains(".padding(.top, HarnessMonitorTheme.spacingLG)"))
  }

  @Test(
    "Session decisions only auto-select when a selected item disappears and routes keep a stable detail target"
  )
  func sessionDecisionAutoSelectionOnlyRunsWhenNeeded() {
    #expect(
      SessionDecisionAutoSelectionPolicy.preferredDecisionID(
        selection: .route(.decisions),
        sessionID: "sess-1",
        allDecisionIDs: ["dec-1", "dec-2"],
        visibleDecisionIDs: ["dec-2", "dec-1"]
      ) == nil
    )
    #expect(
      SessionDecisionAutoSelectionPolicy.preferredDecisionID(
        selection: .decision(sessionID: "sess-1", decisionID: "missing"),
        sessionID: "sess-1",
        allDecisionIDs: ["dec-2"],
        visibleDecisionIDs: ["dec-2"]
      ) == "dec-2"
    )
    #expect(
      SessionDecisionAutoSelectionPolicy.preferredDecisionID(
        selection: .decision(sessionID: "sess-1", decisionID: "dec-1"),
        sessionID: "sess-1",
        allDecisionIDs: ["dec-1", "dec-2"],
        visibleDecisionIDs: ["dec-2"]
      ) == nil
    )
    #expect(
      SessionDecisionAutoSelectionPolicy.preferredRouteDetailDecisionID(
        rememberedDecisionID: "dec-1",
        allDecisionIDs: ["dec-1", "dec-2"],
        visibleDecisionIDs: ["dec-2"]
      ) == "dec-2"
    )
    #expect(
      SessionDecisionAutoSelectionPolicy.preferredRouteDetailDecisionID(
        rememberedDecisionID: nil,
        allDecisionIDs: ["dec-1", "dec-2"],
        visibleDecisionIDs: ["dec-2", "dec-1"]
      ) == "dec-2"
    )
    #expect(
      SessionDecisionAutoSelectionPolicy.preferredRouteDetailDecisionID(
        rememberedDecisionID: "dec-1",
        allDecisionIDs: ["dec-1", "dec-2"],
        visibleDecisionIDs: []
      ) == "dec-1"
    )
  }

  @Test("Summary lists bind selection directly to the session window state")
  func summaryListsBindSelectionDirectlyToSessionState() throws {
    let source = try sourceFile(named: "SessionWindowRouteContent.swift")

    #expect(source.contains("List(selection: selectedAgentIDs)"))
    #expect(source.contains("List(selection: selectedTaskIDs)"))
    #expect(source.contains("List(selection: selectedDecisionIDs)"))
    #expect(source.contains("if case .route(.agents) = state.selection"))
    #expect(source.contains("state.setRouteAgentID(primaryID)"))
    #expect(source.contains("if case .route(.tasks) = state.selection"))
    #expect(source.contains("state.setRouteTaskID(primaryID)"))
    #expect(source.contains("if case .route(.decisions) = state.selection"))
    #expect(source.contains("state.setRouteDecisionID(primaryID)"))
    #expect(!source.contains("@State private var selectedAgentID"))
    #expect(!source.contains("@State private var selectedTaskID"))
    #expect(!source.contains("@State private var selectedDecisionID"))
  }

  @Test("Agents route keeps the route selected while showing the route-selected agent detail")
  func agentsRouteKeepsRouteSelectionWhileShowingTheFirstVisibleAgentDetail() throws {
    let detailFocus = try sourceFile(named: "SessionWindowView+DetailFocus.swift")
    let presentation = try sourceFile(named: "SessionWindowView+Presentation.swift")

    #expect(!presentation.contains("agentsRouteAutoSelectionTrigger"))
    #expect(!presentation.contains("autoSelectFirstVisibleAgentIfNeeded"))
    #expect(detailFocus.contains("case .route(.agents):"))
    #expect(detailFocus.contains("SessionAgentRouteSelectionPolicy.preferredRouteDetailAgentID"))
  }

  @Test("Tasks route keeps the route selected while showing the route-selected task detail")
  func tasksRouteKeepsRouteSelectionWhileShowingTheFirstVisibleTaskDetail() throws {
    let routeContent = try sourceFile(named: "SessionWindowRouteContent.swift")
    let detailFocus = try sourceFile(named: "SessionWindowView+DetailFocus.swift")

    #expect(routeContent.contains("SessionTaskRouteSelectionPolicy.preferredRouteDetailTaskID"))
    #expect(routeContent.contains("state.selectRoute(.tasks)"))
    #expect(detailFocus.contains("case .route(.tasks):"))
    #expect(detailFocus.contains("routeTaskDetailContent()"))
  }

  @Test("Session layouts follow the rendered route when switching route-only surfaces")
  func sessionLayoutsFollowTheRenderedRoute() throws {
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let columns = try sourceFile(named: "SessionWindowView+Columns.swift")

    #expect(windowView.contains("var renderedRoute: SessionWindowRoute"))
    #expect(windowView.contains(".onChange(of: renderedRoute)"))
    #expect(columns.contains("switch renderedRoute.layoutStyle"))
    #expect(columns.contains("case .sidebarDetail"))
    #expect(columns.contains("case .sidebarContentDetail"))
    #expect(columns.contains("contentColumnBody(snapshot: snapshot, route: renderedRoute)"))
  }

  @Test("Create-agent selection swaps the middle pane to runtime configuration")
  func createAgentSelectionSwapsTheMiddlePaneToRuntimeConfiguration() throws {
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let columns = try sourceFile(named: "SessionWindowView+Columns.swift")
    let detailFocus = try sourceFile(named: "SessionWindowView+DetailFocus.swift")

    #expect(
      columns.contains("case .create(let draft) = stateCache.selection, draft.kind == .agent"))
    #expect(columns.contains("SessionWindowCreateAgentRuntimePane("))
    #expect(detailFocus.contains("embedsRuntimeConfiguration: focusMode"))
    #expect(
      windowView.contains(
        "contentColumnWidth = SessionContentDetailSplitLayout.defaultContentWidth"))
  }

  @Test("Timeline route uses the dedicated route page instead of the cockpit section wrapper")
  func timelineRouteUsesTheDedicatedRoutePage() throws {
    let columns = try sourceFile(named: "SessionWindowView+Columns.swift")

    #expect(columns.contains("SessionTimelineView("))
    #expect(columns.contains("style: .routePage"))
    #expect(!columns.contains("MonitorTimelineSection("))
  }

  @Test("Session windows consume pending store route requests")
  func sessionWindowConsumesPendingStoreRouteRequests() throws {
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let presentation = try sourceFile(named: "SessionWindowView+Presentation.swift")

    #expect(presentation.contains(".task(id: store.pendingSessionRouteRequestID)"))
    #expect(windowView.contains("consumePendingSessionRouteRequest(forSessionID: token.sessionID)"))
  }

  @Test("Session-window decision rows keep the shared accessibility contract")
  func decisionRowsKeepSharedAccessibilityContract() throws {
    let columns = try sourceFile(named: "SessionWindowRouteContent.swift")

    #expect(columns.contains("HarnessMonitorAccessibility.decisionRow(decision.id)"))
    #expect(columns.contains(".harnessMCPRow("))
  }

  @Test("Session-window agent and task rows expose stable identifiers")
  func agentAndTaskRowsExposeStableIdentifiers() throws {
    let columns = try sourceFile(named: "SessionWindowRouteContent.swift")

    #expect(columns.contains("HarnessMonitorAccessibility.sessionWindowAgentRow(agent.agentId)"))
    #expect(columns.contains("HarnessMonitorAccessibility.sessionWindowTaskRow(task.taskId)"))
  }

  @Test("Session decisions wire auto-selection into cache recomputation and detail rendering")
  func sessionDecisionsWireAutoSelectionIntoCacheRecomputationAndDetailRendering() throws {
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let columns = try sourceFile(named: "SessionWindowView+Columns.swift")
    let detailFocus = try sourceFile(named: "SessionWindowView+DetailFocus.swift")

    #expect(columns.contains("SessionDecisionAutoSelectionPolicy.preferredDecisionID"))
    #expect(columns.contains("SessionDecisionAutoSelectionPolicy.preferredRouteDetailDecisionID"))
    #expect(columns.contains("stateCache.autoSelectDecision(autoSelectedDecisionID)"))
    #expect(columns.contains("stateCache.setRouteDecisionID(routeDecisionID)"))
    #expect(windowView.contains(".onChange(of: stateCache.sectionState.decisionID)"))
    #expect(detailFocus.contains("case .route(.decisions):"))
    #expect(detailFocus.contains("selectedTab: decisionDetailTabBinding"))
  }

  @Test("Pending route filter resets clear the persisted decision query")
  func pendingRouteFilterResetClearsPersistedDecisionQuery() throws {
    let windowView = try sourceFile(named: "SessionWindowView.swift")

    #expect(windowView.contains("if request.resetDecisionFilters {"))
    #expect(windowView.contains("persistedDecisionQuery = \"\""))
  }

  private func sourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Sessions"
      )
      .appendingPathComponent(name)

    return try String(
      contentsOf: sourceURL,
      encoding: .utf8
    )
  }
}

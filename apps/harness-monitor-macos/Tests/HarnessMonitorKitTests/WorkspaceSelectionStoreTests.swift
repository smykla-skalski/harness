import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Workspace selection bridge")
@MainActor
struct SessionRouteSelectionStoreTests {
  @Test("Fresh store has no pending workspace selection")
  func freshStoreHasNoPendingSelection() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.consumePendingSessionRoute() == nil)
  }

  @Test("requestSessionRoute round-trips the value once")
  func requestRoundTripsOnce() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = SessionRouteSelection.agent(sessionID: nil, agentID: "agent-alpha")
    store.requestSessionRoute(selection)
    #expect(store.consumePendingSessionRoute() == selection)
    #expect(store.consumePendingSessionRoute() == nil)
  }

  @Test("Attention-driven workspace requests carry the decision-filter reset flag")
  func requestCarriesDecisionFilterResetFlag() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = SessionRouteSelection.decisions(sessionID: "sess-alpha")
    store.requestSessionRoute(selection, resetDecisionFilters: true)

    let request = store.consumePendingSessionRouteRequest()

    #expect(request?.selection == selection)
    #expect(request?.resetDecisionFilters == true)
    #expect(store.consumePendingSessionRouteRequest() == nil)
  }

  @Test("Matching session windows consume pending workspace requests")
  func matchingSessionWindowConsumesPendingRequest() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = SessionRouteSelection.decision(
      sessionID: "sess-alpha",
      decisionID: "decision-1"
    )
    store.requestSessionRoute(selection, resetDecisionFilters: true)

    let request = store.consumePendingSessionRouteRequest(forSessionID: "sess-alpha")

    #expect(request?.selection == selection)
    #expect(request?.resetDecisionFilters == true)
    #expect(store.consumePendingSessionRouteRequest(forSessionID: "sess-alpha") == nil)
  }

  @Test("Nonmatching session windows leave pending workspace requests intact")
  func nonmatchingSessionWindowLeavesPendingRequestIntact() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = SessionRouteSelection.task(sessionID: "sess-alpha", taskID: "task-1")
    store.requestSessionRoute(selection)

    #expect(store.consumePendingSessionRouteRequest(forSessionID: "sess-beta") == nil)
    #expect(
      store.consumePendingSessionRouteRequest(forSessionID: "sess-alpha")?.selection == selection)
  }

  @Test("Create requests target the matching session window")
  func createRequestTargetsMatchingSessionWindow() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.requestSessionRouteCreate(.agent, sessionID: "sess-alpha")

    #expect(store.consumePendingSessionRouteRequest(forSessionID: "sess-beta") == nil)
    let request = store.consumePendingSessionRouteRequest(forSessionID: "sess-alpha")
    #expect(request?.selection == .create)
    #expect(request?.createEntryPoint == .agent)
    #expect(request?.createSessionID == "sess-alpha")
  }

  @Test("Create-agent workspace requests carry a selected live session summary")
  func createAgentRequestCarriesEntryPoint() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessionIndex.sessions = [makeSummary(sessionID: "sess-alpha")]
    store.selectedSessionID = "sess-alpha"
    store.requestSessionRouteCreate(.agent)

    let request = store.consumePendingSessionRouteRequest()

    #expect(request?.selection == .create)
    #expect(request?.createEntryPoint == .agent)
    #expect(request?.createSessionID == "sess-alpha")
    #expect(store.consumePendingSessionRouteRequest() == nil)
  }

  @Test("Create-agent workspace requests ignore stale selected session IDs without live context")
  func createAgentRequestIgnoresStaleSelectedSessionID() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-alpha"

    store.requestSessionRouteCreate(.agent)

    let request = store.consumePendingSessionRouteRequest()

    #expect(request?.selection == .create)
    #expect(request?.createEntryPoint == .agent)
    #expect(request?.createSessionID == nil)
  }

  @Test("Create-agent workspace requests ignore cached selected session summaries")
  func createAgentRequestIgnoresCachedSelectedSessionSummary() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.sessionIndex.sessions = [makeSummary(sessionID: "sess-alpha")]
    store.selectedSessionID = "sess-alpha"
    store.isShowingCachedCatalog = true

    store.requestSessionRouteCreate(.agent)

    let request = store.consumePendingSessionRouteRequest()

    #expect(request?.selection == .create)
    #expect(request?.createEntryPoint == .agent)
    #expect(request?.createSessionID == nil)
  }

  @Test("Explicit create-agent workspace requests override the selected session")
  func createAgentRequestUsesExplicitSessionOverride() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.selectedSessionID = "sess-alpha"
    store.requestSessionRouteCreate(.agent, sessionID: "sess-beta")

    let request = store.consumePendingSessionRouteRequest()

    #expect(request?.selection == .create)
    #expect(request?.createEntryPoint == .agent)
    #expect(request?.createSessionID == "sess-beta")
  }

  @Test("Multiple pending requests keep the latest value")
  func latestRequestWins() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.requestSessionRoute(.terminal(sessionID: nil, terminalID: "t-1"))
    store.requestSessionRoute(.codex(sessionID: nil, runID: "c-1"))
    let latest = SessionRouteSelection.agent(sessionID: nil, agentID: "agent-beta")
    store.requestSessionRoute(latest)
    #expect(store.consumePendingSessionRoute() == latest)
    #expect(store.consumePendingSessionRoute() == nil)
  }

  @Test("SessionRouteSelection.agent exposes its agentID accessor")
  func agentAccessorReturnsAgentID() {
    #expect(
      SessionRouteSelection.agent(sessionID: nil, agentID: "agent-gamma").agentID == "agent-gamma"
    )
    #expect(SessionRouteSelection.terminal(sessionID: nil, terminalID: "t-1").agentID == nil)
    #expect(SessionRouteSelection.codex(sessionID: nil, runID: "c-1").agentID == nil)
    #expect(SessionRouteSelection.create.agentID == nil)
    #expect(SessionRouteSelection.task(sessionID: nil, taskID: "task-1").agentID == nil)
  }

  @Test("SessionRouteSelection.task exposes its taskID accessor")
  func taskAccessorReturnsTaskID() {
    #expect(SessionRouteSelection.task(sessionID: nil, taskID: "task-omega").taskID == "task-omega")
    #expect(SessionRouteSelection.terminal(sessionID: nil, terminalID: "t-1").taskID == nil)
    #expect(SessionRouteSelection.codex(sessionID: nil, runID: "c-1").taskID == nil)
    #expect(SessionRouteSelection.agent(sessionID: nil, agentID: "agent-1").taskID == nil)
    #expect(SessionRouteSelection.create.taskID == nil)
  }

  @Test("requestSessionRoute round-trips a task selection")
  func taskSelectionRoundTrips() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = SessionRouteSelection.task(sessionID: nil, taskID: "task-zeta")
    store.requestSessionRoute(selection)
    #expect(store.consumePendingSessionRoute() == selection)
    #expect(store.consumePendingSessionRoute() == nil)
  }

  @Test("Existing terminal/codex accessors keep working")
  func existingAccessorsUnchanged() {
    #expect(SessionRouteSelection.terminal(sessionID: nil, terminalID: "t-1").terminalID == "t-1")
    #expect(SessionRouteSelection.codex(sessionID: nil, runID: "c-1").codexRunID == "c-1")
    #expect(SessionRouteSelection.agent(sessionID: nil, agentID: "agent-delta").terminalID == nil)
    #expect(SessionRouteSelection.agent(sessionID: nil, agentID: "agent-delta").codexRunID == nil)
    #expect(SessionRouteSelection.task(sessionID: nil, taskID: "task-1").terminalID == nil)
    #expect(SessionRouteSelection.task(sessionID: nil, taskID: "task-1").codexRunID == nil)
  }

  private func makeSummary(sessionID: String) -> SessionSummary {
    SessionSummary(
      projectId: "project-\(sessionID)",
      projectName: "harness",
      projectDir: "/Users/example/Projects/harness",
      contextRoot: "/Users/example/Library/Application Support/harness/sessions/harness",
      sessionId: sessionID,
      worktreePath: "/Users/example/Projects/harness-\(sessionID)",
      sharedPath: "/Users/example/Projects/harness-\(sessionID)/shared",
      originPath: "/Users/example/Projects/harness",
      branchRef: "harness/\(sessionID)",
      title: "Session \(sessionID)",
      context: "Workspace selection fixture",
      status: .active,
      createdAt: "2026-03-28T14:05:00Z",
      updatedAt: "2026-03-28T14:18:00Z",
      lastActivityAt: "2026-03-28T14:18:00Z",
      leaderId: "leader-\(sessionID)",
      observeId: "observe-\(sessionID)",
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 1,
        activeAgentCount: 1,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      ),
    )
  }
}

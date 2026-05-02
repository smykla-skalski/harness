import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Workspace selection bridge")
@MainActor
struct WorkspaceSelectionStoreTests {
  @Test("Fresh store has no pending workspace selection")
  func freshStoreHasNoPendingSelection() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.consumePendingWorkspaceSelection() == nil)
  }

  @Test("requestWorkspaceSelection round-trips the value once")
  func requestRoundTripsOnce() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = WorkspaceSelection.agent(sessionID: nil, agentID: "agent-alpha")
    store.requestWorkspaceSelection(selection)
    #expect(store.consumePendingWorkspaceSelection() == selection)
    #expect(store.consumePendingWorkspaceSelection() == nil)
  }

  @Test("Attention-driven workspace requests carry the decision-filter reset flag")
  func requestCarriesDecisionFilterResetFlag() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = WorkspaceSelection.decisions(sessionID: "sess-alpha")
    store.requestWorkspaceSelection(selection, resetDecisionFilters: true)

    let request = store.consumePendingWorkspaceSelectionRequest()

    #expect(request?.selection == selection)
    #expect(request?.resetDecisionFilters == true)
    #expect(store.consumePendingWorkspaceSelectionRequest() == nil)
  }

  @Test("Multiple pending requests keep the latest value")
  func latestRequestWins() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.requestWorkspaceSelection(.terminal(sessionID: nil, terminalID: "t-1"))
    store.requestWorkspaceSelection(.codex(sessionID: nil, runID: "c-1"))
    let latest = WorkspaceSelection.agent(sessionID: nil, agentID: "agent-beta")
    store.requestWorkspaceSelection(latest)
    #expect(store.consumePendingWorkspaceSelection() == latest)
    #expect(store.consumePendingWorkspaceSelection() == nil)
  }

  @Test("WorkspaceSelection.agent exposes its agentID accessor")
  func agentAccessorReturnsAgentID() {
    #expect(
      WorkspaceSelection.agent(sessionID: nil, agentID: "agent-gamma").agentID == "agent-gamma"
    )
    #expect(WorkspaceSelection.terminal(sessionID: nil, terminalID: "t-1").agentID == nil)
    #expect(WorkspaceSelection.codex(sessionID: nil, runID: "c-1").agentID == nil)
    #expect(WorkspaceSelection.create.agentID == nil)
    #expect(WorkspaceSelection.task(sessionID: nil, taskID: "task-1").agentID == nil)
  }

  @Test("WorkspaceSelection.task exposes its taskID accessor")
  func taskAccessorReturnsTaskID() {
    #expect(WorkspaceSelection.task(sessionID: nil, taskID: "task-omega").taskID == "task-omega")
    #expect(WorkspaceSelection.terminal(sessionID: nil, terminalID: "t-1").taskID == nil)
    #expect(WorkspaceSelection.codex(sessionID: nil, runID: "c-1").taskID == nil)
    #expect(WorkspaceSelection.agent(sessionID: nil, agentID: "agent-1").taskID == nil)
    #expect(WorkspaceSelection.create.taskID == nil)
  }

  @Test("requestWorkspaceSelection round-trips a task selection")
  func taskSelectionRoundTrips() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let selection = WorkspaceSelection.task(sessionID: nil, taskID: "task-zeta")
    store.requestWorkspaceSelection(selection)
    #expect(store.consumePendingWorkspaceSelection() == selection)
    #expect(store.consumePendingWorkspaceSelection() == nil)
  }

  @Test("Existing terminal/codex accessors keep working")
  func existingAccessorsUnchanged() {
    #expect(WorkspaceSelection.terminal(sessionID: nil, terminalID: "t-1").terminalID == "t-1")
    #expect(WorkspaceSelection.codex(sessionID: nil, runID: "c-1").codexRunID == "c-1")
    #expect(WorkspaceSelection.agent(sessionID: nil, agentID: "agent-delta").terminalID == nil)
    #expect(WorkspaceSelection.agent(sessionID: nil, agentID: "agent-delta").codexRunID == nil)
    #expect(WorkspaceSelection.task(sessionID: nil, taskID: "task-1").terminalID == nil)
    #expect(WorkspaceSelection.task(sessionID: nil, taskID: "task-1").codexRunID == nil)
  }
}

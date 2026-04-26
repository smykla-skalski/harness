import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Agents window selection bridge")
@MainActor
struct AgentsWindowSelectionStoreTests {
  @Test("Fresh store has no pending agents-window selection")
  func freshStoreHasNoPendingSelection() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.consumePendingAgentsWindowSelection() == nil)
  }

  @Test("requestAgentsWindowSelection round-trips the value once")
  func requestRoundTripsOnce() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.requestAgentsWindowSelection(.agent("agent-alpha"))
    #expect(store.consumePendingAgentsWindowSelection() == .agent("agent-alpha"))
    #expect(store.consumePendingAgentsWindowSelection() == nil)
  }

  @Test("Multiple pending requests keep the latest value")
  func latestRequestWins() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.requestAgentsWindowSelection(.terminal("t-1"))
    store.requestAgentsWindowSelection(.codex("c-1"))
    store.requestAgentsWindowSelection(.agent("agent-beta"))
    #expect(store.consumePendingAgentsWindowSelection() == .agent("agent-beta"))
    #expect(store.consumePendingAgentsWindowSelection() == nil)
  }

  @Test("AgentTuiSheetSelection.agent exposes its agentID accessor")
  func agentAccessorReturnsAgentID() {
    #expect(AgentTuiSheetSelection.agent("agent-gamma").agentID == "agent-gamma")
    #expect(AgentTuiSheetSelection.terminal("t-1").agentID == nil)
    #expect(AgentTuiSheetSelection.codex("c-1").agentID == nil)
    #expect(AgentTuiSheetSelection.create.agentID == nil)
    #expect(AgentTuiSheetSelection.task("task-1").agentID == nil)
  }

  @Test("AgentTuiSheetSelection.task exposes its taskID accessor")
  func taskAccessorReturnsTaskID() {
    #expect(AgentTuiSheetSelection.task("task-omega").taskID == "task-omega")
    #expect(AgentTuiSheetSelection.terminal("t-1").taskID == nil)
    #expect(AgentTuiSheetSelection.codex("c-1").taskID == nil)
    #expect(AgentTuiSheetSelection.agent("agent-1").taskID == nil)
    #expect(AgentTuiSheetSelection.create.taskID == nil)
  }

  @Test("requestAgentsWindowSelection round-trips a task selection")
  func taskSelectionRoundTrips() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.requestAgentsWindowSelection(.task("task-zeta"))
    #expect(store.consumePendingAgentsWindowSelection() == .task("task-zeta"))
    #expect(store.consumePendingAgentsWindowSelection() == nil)
  }

  @Test("Existing terminal/codex accessors keep working")
  func existingAccessorsUnchanged() {
    #expect(AgentTuiSheetSelection.terminal("t-1").terminalID == "t-1")
    #expect(AgentTuiSheetSelection.codex("c-1").codexRunID == "c-1")
    #expect(AgentTuiSheetSelection.agent("agent-delta").terminalID == nil)
    #expect(AgentTuiSheetSelection.agent("agent-delta").codexRunID == nil)
    #expect(AgentTuiSheetSelection.task("task-1").terminalID == nil)
    #expect(AgentTuiSheetSelection.task("task-1").codexRunID == nil)
  }
}

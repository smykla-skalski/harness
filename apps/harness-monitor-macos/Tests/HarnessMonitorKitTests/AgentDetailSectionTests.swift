import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("AgentDetailSection skeleton")
@MainActor
struct AgentDetailSectionTests {
  @Test("Section publishes the workspace detail accessibility identifier")
  func publishesAccessibilityIdentifier() {
    #expect(HarnessMonitorAccessibility.agentDetailCard == "harness.agent.detail-card")
  }

  @Test("Section publishes external-addition accessibility identifiers")
  func publishesExternalAdditionIdentifiers() {
    #expect(
      HarnessMonitorAccessibility.agentDetailPersona
        == "harness.agent.detail.persona"
    )
    #expect(
      HarnessMonitorAccessibility.agentDetailAssignedTasks
        == "harness.agent.detail.assigned-tasks"
    )
    #expect(
      HarnessMonitorAccessibility.agentDetailTimeline
        == "harness.agent.detail.timeline"
    )
  }

  @Test("Section publishes role-action accessibility identifiers")
  func publishesRoleActionIdentifiers() {
    #expect(
      HarnessMonitorAccessibility.agentDetailRolePicker
        == "harness.agent.detail.role-picker"
    )
    #expect(
      HarnessMonitorAccessibility.agentDetailRoleChange
        == "harness.agent.detail.role-change"
    )
    #expect(
      HarnessMonitorAccessibility.agentDetailRoleRemove
        == "harness.agent.detail.role-remove"
    )
    #expect(
      HarnessMonitorAccessibility.agentDetailSignalDisclosure
        == "harness.agent.detail.signal-disclosure"
    )
    #expect(
      HarnessMonitorAccessibility.agentDetailSignalStatus
        == "harness.agent.detail.signal-status"
    )
  }

  @Test("Section accepts an agent + activity and conforms to View")
  func constructsForAgent() {
    let agent = AgentRegistration(
      agentId: "agent-detail-fixture",
      name: "Fixture Agent",
      runtime: "claude",
      role: .worker,
      capabilities: ["alpha"],
      joinedAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 1,
        hookPoints: []
      ),
      persona: nil
    )
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let section = AgentDetailSection(store: store, agent: agent, activity: nil)
    _ = AnyView(section)
  }

  @Test("Role picker clamps stale leader draft state to the current agent role")
  func rolePickerClampsStaleLeaderDraft() {
    #expect(
      AgentDetailSection.normalizedRoleSelection(
        draftRole: .leader,
        agentRole: .worker
      ) == .worker
    )
  }

  @Test("Role picker includes a leader tag when the current agent role is leader")
  func rolePickerIncludesLeaderWhenCurrentAgentIsLeader() {
    #expect(
      AgentDetailSection.rolePickerOptions(for: .worker) == [
        .observer,
        .worker,
        .reviewer,
        .improver,
      ]
    )
    #expect(AgentDetailSection.rolePickerOptions(for: .leader) == SessionRole.allCases)
  }

  @Test("Role changes submit the normalized picker value")
  func roleChangesSubmitNormalizedPickerValue() {
    #expect(
      AgentDetailSection.submittedRoleSelection(
        draftRole: .leader,
        agentRole: .worker
      ) == .worker
    )
    #expect(
      AgentDetailSection.submittedRoleSelection(
        draftRole: .reviewer,
        agentRole: .worker
      ) == .reviewer
    )
  }

  @Test("Send update composer expands advanced options for custom type or saved context")
  func sendUpdateComposerExpandsAdvancedOptionsWhenNeeded() {
    #expect(
      AgentDetailSendUpdateSection.prefersExpandedAdvancedOptions(
        selectedSendAction: .custom,
        actionHint: ""
      )
    )
    #expect(
      AgentDetailSendUpdateSection.prefersExpandedAdvancedOptions(
        selectedSendAction: .injectContext,
        actionHint: "Keep the scope narrow."
      )
    )
    #expect(
      !AgentDetailSendUpdateSection.prefersExpandedAdvancedOptions(
        selectedSendAction: .injectContext,
        actionHint: "   "
      )
    )
  }

  @Test("Send update composer status copy covers read-only and missing draft content")
  func sendUpdateComposerStatusCopy() {
    #expect(
      AgentDetailSendUpdateSection.statusMessage(
        isSessionReadOnly: true,
        actionUnavailableMessage: nil,
        trimmedCommand: SendUpdateAction.injectContext.rawCommand,
        trimmedMessage: "Follow up"
      ) == "Read-only session — open a writable session to send updates."
    )
    #expect(
      AgentDetailSendUpdateSection.statusMessage(
        isSessionReadOnly: false,
        actionUnavailableMessage: "Leader unavailable",
        trimmedCommand: "",
        trimmedMessage: "Follow up"
      ) == "Leader unavailable"
    )
    #expect(
      AgentDetailSendUpdateSection.statusMessage(
        isSessionReadOnly: false,
        actionUnavailableMessage: nil,
        trimmedCommand: SendUpdateAction.injectContext.rawCommand,
        trimmedMessage: ""
      ) == "Type a message to send."
    )
    #expect(
      AgentDetailSendUpdateSection.statusMessage(
        isSessionReadOnly: false,
        actionUnavailableMessage: nil,
        trimmedCommand: SendUpdateAction.injectContext.rawCommand,
        trimmedMessage: "Follow up"
      ) == nil
    )
  }

  @Test("Leader transfer picker clamps a stale leader-like ID before render")
  func leaderTransferClampsStaleSelection() {
    #expect(
      LeaderTransferSheet.normalizedTransferLeaderID(
        draftID: "leader",
        leaderID: "leader-claude",
        pendingLeaderID: nil,
        availableAgentIDs: ["leader-claude", "worker-codex", "worker-gemini"]
      ) == "worker-codex"
    )
  }

  @Test("Leader transfer picker keeps a valid pending transfer selection")
  func leaderTransferKeepsPendingSelection() {
    #expect(
      LeaderTransferSheet.normalizedTransferLeaderID(
        draftID: "",
        leaderID: "leader-claude",
        pendingLeaderID: "worker-gemini",
        availableAgentIDs: ["leader-claude", "worker-codex", "worker-gemini"]
      ) == "worker-gemini"
    )
  }

  @Test("Task actions assignee picker clamps a stale leader-like ID before render")
  func taskActionsClampStaleAssigneeSelection() {
    #expect(
      TaskActionsSheet.normalizedAssigneeID(
        draftID: "leader",
        assignedAgentID: nil,
        availableAgentIDs: ["worker-codex", "worker-gemini"]
      ) == "worker-codex"
    )
  }

  @Test("Task actions keep a valid draft reassignment when the task already has an assignee")
  func taskActionsPreferValidDraftReassignment() {
    #expect(
      TaskActionsSheet.normalizedAssigneeID(
        draftID: "worker-gemini",
        assignedAgentID: "worker-codex",
        availableAgentIDs: ["worker-codex", "worker-gemini"]
      ) == "worker-gemini"
    )
  }

  @Test("Task actions task picker stays scoped to the presented task")
  func taskActionsKeepPresentedTaskSelection() {
    #expect(
      TaskActionsSheet.normalizedTaskID(
        draftID: "stale-task",
        currentTaskID: "task-ui",
        availableTaskIDs: ["task-ui", "task-routing"]
      ) == "task-ui"
    )
  }

  @Test("Native transcript agents read the dedicated ACP transcript slice")
  func nativeTranscriptAgentsReadDedicatedTranscriptSlice() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.timeline = makeTimelineEntries(
      sessionID: "sess-agent-detail",
      agentID: "agent-native",
      summary: "Cockpit timeline row"
    )
    store.selectedAcpTranscriptHistoryEntries = [
      TimelineEntry(
        entryId: "acp-native-row",
        recordedAt: "2026-04-28T00:00:20Z",
        kind: "assistant_message",
        sessionId: "sess-agent-detail",
        agentId: "agent-native",
        taskId: nil,
        summary: "Dedicated ACP transcript row",
        payload: .object(["runtime": .string("acp")])
      )
    ]

    let nativeAgent = AgentRegistration(
      agentId: "agent-native",
      name: "Native Agent",
      runtime: "copilot",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "copilot",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 1,
        hookPoints: []
      ),
      persona: nil
    )
    let legacyAgent = AgentRegistration(
      agentId: "agent-native",
      name: "Legacy Agent",
      runtime: "claude",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-04-22T09:00:00Z",
      updatedAt: "2026-04-22T09:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: false,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 1,
        hookPoints: []
      ),
      persona: nil
    )

    #expect(
      AgentDetailSection.transcriptEntries(store: store, agent: nativeAgent).map(\.summary)
        == ["Dedicated ACP transcript row"]
    )
    #expect(
      AgentDetailSection.transcriptEntries(store: store, agent: legacyAgent).map(\.summary)
        == ["Cockpit timeline row"]
    )
  }
}

import HarnessMonitorKit
import SwiftUI

struct SessionCockpitView: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]
  let isSessionReadOnly: Bool
  let isExtensionsLoading: Bool
  @Environment(\.openWindow) private var openWindow

  private var tuiStatusByAgent: [String: AgentTuiStatus] {
    var snapshotStatus: [String: AgentTuiStatus] = [:]
    snapshotStatus.reserveCapacity(store.selectedAgentTuis.count)
    for tui in store.selectedAgentTuis {
      if let existing = snapshotStatus[tui.agentId] {
        if tui.status.isActive && !existing.isActive {
          snapshotStatus[tui.agentId] = tui.status
        }
      } else {
        snapshotStatus[tui.agentId] = tui.status
      }
    }

    var result: [String: AgentTuiStatus] = [:]
    result.reserveCapacity(detail.agents.count)
    for agent in detail.agents {
      if let status = snapshotStatus[agent.agentId] {
        result[agent.agentId] = status
      } else if agent.capabilities.contains("agent-tui") {
        result[agent.agentId] = agent.status == .active ? .running : .exited
      }
    }
    return result
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      verticalPadding: HarnessMonitorTheme.spacingXL,
      constrainContentWidth: true
    ) {
      VStack(alignment: .leading, spacing: 16) {
        SessionCockpitHeaderCard(
          store: store,
          detail: detail,
          isSessionReadOnly: isSessionReadOnly,
          observeSelectedSession: { Task { await store.observeSelectedSession() } },
          requestEndSessionConfirmation: store.requestEndSelectedSessionConfirmation,
          inspectObserver: store.inspectObserver
        )
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(
          detail: detail,
          inspectTask: store.inspect(taskID:),
          inspectAgent: store.inspect(agentID:),
          inspectObserver: store.inspectObserver,
          openAgentTui: { openWindow(id: HarnessMonitorWindowID.agentTui) },
          isCodexFlowAvailable: store.isCodexFlowAvailable,
          openCodexFlow: store.presentCodexFlowSheet
        )
        HarnessMonitorAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
          SessionTaskListSection(
            store: store,
            sessionID: detail.session.sessionId,
            tasks: detail.tasks,
            companionAgentCount: detail.agents.count,
            inspectTask: store.inspect(taskID:)
          )
          SessionAgentListSection(
            store: store,
            sessionID: detail.session.sessionId,
            agents: detail.agents,
            tasks: detail.tasks,
            isSessionReadOnly: isSessionReadOnly,
            inspectAgent: store.inspect(agentID:),
            tuiStatusByAgent: tuiStatusByAgent
          )
        }
        SessionCockpitSignalsSection(
          store: store,
          signals: detail.signals,
          isExtensionsLoading: isExtensionsLoading,
          isSessionReadOnly: isSessionReadOnly
        )
        SessionCockpitTimelineSection(
          sessionID: detail.session.sessionId,
          timeline: timeline
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    isSessionReadOnly: false,
    isExtensionsLoading: false
  )
}

#Preview("Cockpit - TUI agents") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .agentTuiOverflow),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    isSessionReadOnly: false,
    isExtensionsLoading: false
  )
}

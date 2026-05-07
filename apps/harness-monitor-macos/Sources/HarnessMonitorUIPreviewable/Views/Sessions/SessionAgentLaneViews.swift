import HarnessMonitorKit
import SwiftUI

struct SessionAgentListSection: View {
  let store: HarnessMonitorStore
  let sessionID: String
  let sessionStatus: SessionStatus
  let agents: [AgentRegistration]
  let tasks: [WorkItem]
  let isSessionReadOnly: Bool
  let openAgent: (String) -> Void
  let tuiStatusByAgent: [String: AgentTuiStatus]
  @Environment(\.openWindow)
  private var openWindow

  private var agentStateMarkerText: String {
    let agentIDs = agents.map(\.agentId).joined(separator: ",")
    let runtimes = Array(Set(agents.map(\.runtime))).sorted().joined(separator: ",")
    return "agentCount=\(agents.count), agentIDs=\(agentIDs), runtimes=\(runtimes)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.sessionAgentListState,
        text: agentStateMarkerText
      )
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
        Text("Agents")
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        newAgentButton
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityTestProbe(
        HarnessMonitorAccessibility.sessionAgentListHeader,
        label: "Agents"
      )
      .accessibilityFrameMarker(HarnessMonitorAccessibility.sessionAgentListHeaderFrame)
      if agents.isEmpty {
        if sessionStatus == .awaitingLeader {
          HStack(spacing: 0) {
            Text("No agents yet. Join a leader to activate this session.")
              .scaledFont(SessionCockpitEmptyStateRow.baseFont)
              .foregroundStyle(.secondary)
            Spacer(minLength: 0)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text("No agents yet. Join a leader to activate this session."))
          .accessibilityIdentifier(
            SessionCockpitEmptyStateRow.Section.agents.accessibilityIdentifier
          )
        } else {
          SessionCockpitEmptyStateRow(section: .agents)
        }
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          ForEach(agents) { agent in
            SessionAgentSummaryCard(
              store: store,
              sessionID: sessionID,
              agent: agent,
              queuedTasks: tasks.queued(for: agent.agentId),
              isSessionReadOnly: isSessionReadOnly,
              openAgent: openAgent,
              tuiStatus: tuiStatusByAgent[agent.agentId]
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var newAgentButton: some View {
    HarnessMonitorActionButton(
      title: "New Agent",
      variant: .bordered,
      accessibilityIdentifier: HarnessMonitorAccessibility.sessionAgentCreateOpenButton
    ) {
      openNewAgent()
    }
    .help("Open workspace and create a new agent")
  }

  private func openNewAgent() {
    store.requestWorkspaceCreateEntryPoint(.agent, sessionID: sessionID)
    openWindow.openHarnessSessionWindow(sessionID: sessionID)
  }
}

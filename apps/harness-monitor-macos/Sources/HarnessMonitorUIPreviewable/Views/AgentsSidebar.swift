import HarnessMonitorKit
import SwiftUI

struct AgentsSidebar: View {
  let store: HarnessMonitorStore
  @Binding var selection: WorkspaceSelection
  let createMode: AgentTuiCreateMode
  @Binding var decisionFilters: DecisionsSidebarViewModel.FilterState
  let decisionScope: DecisionWorkspaceScope
  let currentSessionID: String?
  let currentSessionTitle: String?
  let agentTuis: [AgentTuiSnapshot]
  let sessionTitlesByID: [String: String]
  let codexRuns: [CodexRunSnapshot]
  let codexTitlesByID: [String: String]
  let externalAgents: [AgentRegistration]
  let pendingDecisionAttention: [String: AcpDecisionAttention]
  let openPendingDecisions: (String) -> Void
  let tasks: [WorkItem]
  let refresh: () -> Void

  @State private var decisionQuery = ""
  @AppStorage("harness.decisions.sidebar.filterExpanded")
  private var decisionFilterExpanded = true
  @AppStorage("harness.decisions.sidebar.severitiesCSV")
  private var decisionSeveritiesCSV = ""
  @AppStorage("harness.decisions.sidebar.searchScope")
  private var decisionSearchScopeRaw = DecisionsSidebarSearchScope.summary.rawValue
  @Environment(\.fontScale)
  private var fontScale

  private var rowPadding: CGFloat {
    HarnessMonitorTheme.spacingXS * fontScale
  }

  private var selectionBinding: Binding<WorkspaceSelection?> {
    Binding(
      get: { selection },
      set: { selection = $0 ?? .create }
    )
  }

  private var activeTuis: [AgentTuiSnapshot] {
    agentTuis.filter { $0.status.isActive }
  }

  private var inactiveTuis: [AgentTuiSnapshot] {
    agentTuis.filter { !$0.status.isActive }
  }

  private var activeCodexRuns: [CodexRunSnapshot] {
    codexRuns.filter { $0.status.isActive }
  }

  private var inactiveCodexRuns: [CodexRunSnapshot] {
    codexRuns.filter { !$0.status.isActive }
  }

  var body: some View {
    List(selection: selectionBinding) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: "plus.rectangle")
          .accessibilityHidden(true)
        Text(createMode.sidebarTitle)
          .scaledFont(.body)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, rowPadding)
        .tag(WorkspaceSelection.create)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiCreateTab)

      AgentsSidebarDecisionSection(
        selection: $selection,
        decisionFilters: $decisionFilters,
        scope: decisionScope,
        currentSessionID: currentSessionID,
        currentSessionTitle: currentSessionTitle,
        fontScale: fontScale,
        decisionQuery: $decisionQuery,
        decisionFilterExpanded: $decisionFilterExpanded,
        decisionSeveritiesCSV: $decisionSeveritiesCSV,
        decisionSearchScopeRaw: $decisionSearchScopeRaw,
        acpPayload: acpPayload(for:),
        lastMessageAt: lastAcpMessageAt(for:)
      )

      if !externalAgents.isEmpty {
        Section("Connected Agents") {
          ForEach(externalAgents) { agent in
            externalAgentRow(agent)
              .tag(WorkspaceSelection.agent(sessionID: currentSessionID, agentID: agent.agentId))
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.agentTuiExternalTab(agent.agentId)
              )
              .accessibilityFrameMarker(
                "\(HarnessMonitorAccessibility.agentTuiExternalTab(agent.agentId)).frame"
              )
          }
        }
      }

      if !activeTuis.isEmpty {
        Section("Open Sessions") {
          ForEach(activeTuis) { tui in
            AgentsSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Session"
            )
            .padding(.vertical, rowPadding)
            .tag(WorkspaceSelection.terminal(sessionID: tui.sessionId, terminalID: tui.tuiId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(tui.tuiId))
          }
        }
      }

      if !inactiveTuis.isEmpty {
        Section("Past Sessions") {
          ForEach(inactiveTuis) { tui in
            AgentsSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Session"
            )
            .padding(.vertical, rowPadding)
            .tag(WorkspaceSelection.terminal(sessionID: tui.sessionId, terminalID: tui.tuiId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(tui.tuiId))
          }
        }
      }

      if !activeCodexRuns.isEmpty {
        Section("Open Runs") {
          ForEach(activeCodexRuns) { run in
            CodexRunSidebarRow(
              snapshot: run,
              title: codexTitlesByID[run.runId] ?? "Run"
            )
            .padding(.vertical, rowPadding)
            .tag(WorkspaceSelection.codex(sessionID: run.sessionId, runID: run.runId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(run.runId))
          }
        }
      }

      if !inactiveCodexRuns.isEmpty {
        Section("Past Runs") {
          ForEach(inactiveCodexRuns) { run in
            CodexRunSidebarRow(
              snapshot: run,
              title: codexTitlesByID[run.runId] ?? "Run"
            )
            .padding(.vertical, rowPadding)
            .tag(WorkspaceSelection.codex(sessionID: run.sessionId, runID: run.runId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiTab(run.runId))
          }
        }
      }

      if !tasks.isEmpty {
        Section("Tasks") {
          ForEach(tasks, id: \.taskId) { task in
            HStack(spacing: HarnessMonitorTheme.spacingSM) {
              Image(systemName: "checklist")
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                  .scaledFont(.body)
                  .lineLimit(2)
                Text("\(task.severity.title) • \(task.status.title)")
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, rowPadding)
            .tag(WorkspaceSelection.task(sessionID: currentSessionID, taskID: task.taskId))
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentsTaskTab(task.taskId))
          }
        }
      }
    }
    .listStyle(.sidebar)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button(action: refresh) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRefreshButton)
      }
    }
  }

  @ViewBuilder
  private func externalAgentRow(_ agent: AgentRegistration) -> some View {
    let pendingDecisionBadgeID =
      HarnessMonitorAccessibility.agentPendingDecisionBadge(agent.agentId)
    let attention = pendingDecisionAttention[agent.agentId]

    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "person.crop.circle")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      VStack(alignment: .leading, spacing: 2) {
        Text(agent.name)
          .scaledFont(.body)
        Text("\(runtimeDisplayLabel(agent.runtime)) • \(agent.role.title)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if let attention {
        AgentAttentionBadge(
          count: attention.count,
          accessibilityIdentifier: HarnessMonitorUITestEnvironment
            .accessibilityMarkersEnabled ? nil : pendingDecisionBadgeID
        ) {
          openPendingDecisions(agent.agentId)
        }
        .harnessUITestValue("count=\(attention.count) batch=\(attention.oldestBatchID)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture {
      selection = .agent(sessionID: currentSessionID, agentID: agent.agentId)
    }
    .overlay(alignment: .topTrailing) {
      if agent.isAutoSpawned {
        AutoSpawnedBadgeView(agentID: agent.agentId)
          .allowsHitTesting(false)
      }
    }
    .padding(.vertical, rowPadding)
    .accessibilityTestProbe(
      pendingDecisionBadgeID,
      label: "Pending decisions",
      value: attention.map { "count=\($0.count) batch=\($0.oldestBatchID)" } ?? "count=0"
    )
  }

  private func lastAcpMessageAt(
    for decision: Decision
  ) -> Date? {
    store.acpPermissionLastSignalAt(sessionID: decision.sessionID)
  }

  private func acpPayload(
    for decision: Decision
  ) -> AcpPermissionDecisionPayload? {
    guard decision.ruleID == AcpPermissionDecisionPayload.ruleID else {
      return nil
    }
    return store.acpPermissionDecisionPayload(for: decision.id)
      ?? AcpPermissionDecisionPayload.decode(from: decision)
  }

}

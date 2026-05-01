import HarnessMonitorKit
import SwiftUI

struct WorkspaceSidebar: View {
  let store: HarnessMonitorStore
  @Binding var selection: WorkspaceSelection
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

  @AppStorage("harness.workspace.sidebar.severitiesCSV")
  private var decisionSeveritiesCSV = ""
  @AppStorage("harness.workspace.sidebar.searchScope")
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

  private var decisionSearchText: Binding<String> {
    Binding(
      get: { decisionFilters.query },
      set: { updateDecisionFilters(query: $0) }
    )
  }

  private var decisionSearchScope: Binding<DecisionsSidebarSearchScope> {
    Binding(
      get: { decisionFilters.scope },
      set: { updateDecisionFilters(scope: $0) }
    )
  }

  private var persistedDecisionSeverities: Set<DecisionSeverity> {
    Set(
      decisionSeveritiesCSV
        .split(separator: ",")
        .compactMap { DecisionSeverity(rawValue: String($0)) }
    )
  }

  private var decisionFiltersMenuEnabled: Bool {
    decisionScope.totalCount > 0 || !decisionFilters.severities.isEmpty
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
        Text("Create")
          .scaledFont(.body)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, rowPadding)
      .tag(WorkspaceSelection.create)
      .accessibilityElement(children: .combine)
      .harnessMCPTab(
        HarnessMonitorAccessibility.agentTuiCreateTab,
        label: "Create",
        pressAction: { selection = .create }
      )

      WorkspaceSidebarDecisionSection(
        selection: $selection,
        decisionFilters: $decisionFilters,
        scope: decisionScope,
        currentSessionID: currentSessionID,
        currentSessionTitle: currentSessionTitle,
        fontScale: fontScale,
        acpPayload: acpPayload(for:),
        lastMessageAt: lastAcpMessageAt(for:)
      )

      if !externalAgents.isEmpty {
        Section("Connected Agents") {
          ForEach(externalAgents) { agent in
            externalAgentRow(agent)
              .tag(WorkspaceSelection.agent(sessionID: currentSessionID, agentID: agent.agentId))
               .harnessMCPTab(
                 HarnessMonitorAccessibility.agentTuiExternalTab(agent.agentId),
                 label: agent.name,
                 pressAction: {
                   selection = .agent(sessionID: currentSessionID, agentID: agent.agentId)
                 }
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
            WorkspaceSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Session"
            )
            .padding(.vertical, rowPadding)
            .tag(WorkspaceSelection.terminal(sessionID: tui.sessionId, terminalID: tui.tuiId))
             .harnessMCPTab(
               HarnessMonitorAccessibility.agentTuiTab(tui.tuiId),
               label: sessionTitlesByID[tui.tuiId] ?? "Session",
               pressAction: {
                 selection = .terminal(sessionID: tui.sessionId, terminalID: tui.tuiId)
               }
             )
          }
        }
      }

      if !inactiveTuis.isEmpty {
        Section("Past Sessions") {
          ForEach(inactiveTuis) { tui in
            WorkspaceSidebarRow(
              snapshot: tui,
              title: sessionTitlesByID[tui.tuiId] ?? "Session"
            )
            .padding(.vertical, rowPadding)
            .tag(WorkspaceSelection.terminal(sessionID: tui.sessionId, terminalID: tui.tuiId))
             .harnessMCPTab(
               HarnessMonitorAccessibility.agentTuiTab(tui.tuiId),
               label: sessionTitlesByID[tui.tuiId] ?? "Session",
               pressAction: {
                 selection = .terminal(sessionID: tui.sessionId, terminalID: tui.tuiId)
               }
             )
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
             .harnessMCPTab(
               HarnessMonitorAccessibility.agentTuiTab(run.runId),
               label: codexTitlesByID[run.runId] ?? "Run",
               pressAction: {
                 selection = .codex(sessionID: run.sessionId, runID: run.runId)
               }
             )
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
             .harnessMCPTab(
               HarnessMonitorAccessibility.agentTuiTab(run.runId),
               label: codexTitlesByID[run.runId] ?? "Run",
               pressAction: {
                 selection = .codex(sessionID: run.sessionId, runID: run.runId)
               }
             )
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
             .harnessMCPRow(
               HarnessMonitorAccessibility.workspaceTaskTab(task.taskId),
               label: task.title,
               value: "\(task.severity.title) • \(task.status.title)",
               pressAction: {
                 selection = .task(sessionID: currentSessionID, taskID: task.taskId)
               }
             )
          }
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      WorkspaceSidebarDecisionFilterStateMarker(
        filters: decisionFilters,
        decisionScope: decisionScope
      )
    }
    .searchable(
      text: decisionSearchText,
      placement: .sidebar,
      prompt: Text("Search decisions")
    )
    .searchScopes(decisionSearchScope, activation: .onSearchPresentation) {
      ForEach(DecisionsSidebarSearchScope.allCases) { scope in
        Text(scope.label).tag(scope)
      }
    }
    .toolbar {
      WorkspaceSidebarDecisionFilterToolbarItem(
        selectedSeverities: decisionFilters.severities,
        isEnabled: decisionFiltersMenuEnabled,
        setSelectedSeverities: setDecisionSeverities
      )
    }
    .onAppear {
      restorePersistedDecisionFiltersIfNeeded()
    }
    .onChange(of: decisionFilters) { _, newValue in
      syncPersistedDecisionPreferences(from: newValue)
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

  private func restorePersistedDecisionFiltersIfNeeded() {
    let isDefaultState =
      decisionFilters.query.isEmpty
      && decisionFilters.severities.isEmpty
      && decisionFilters.scope == .summary
    if isDefaultState {
      updateDecisionFilters(
        severities: persistedDecisionSeverities,
        scope: DecisionsSidebarSearchScope(rawValue: decisionSearchScopeRaw) ?? .summary
      )
    } else {
      syncPersistedDecisionPreferences(from: decisionFilters)
    }
  }

  private func setDecisionSeverities(_ newValue: Set<DecisionSeverity>) {
    updateDecisionFilters(severities: newValue)
  }

  private func updateDecisionFilters(
    query: String? = nil,
    severities: Set<DecisionSeverity>? = nil,
    scope: DecisionsSidebarSearchScope? = nil
  ) {
    let next = DecisionsSidebarViewModel.FilterState(
      query: query ?? decisionFilters.query,
      severities: severities ?? decisionFilters.severities,
      scope: scope ?? decisionFilters.scope
    )
    guard next != decisionFilters else {
      syncPersistedDecisionPreferences(from: next)
      return
    }
    decisionFilters = next
    syncPersistedDecisionPreferences(from: next)
  }

  private func syncPersistedDecisionPreferences(
    from filters: DecisionsSidebarViewModel.FilterState
  ) {
    let severityCSV = filters.severities.map(\.rawValue).sorted().joined(separator: ",")
    if decisionSeveritiesCSV != severityCSV {
      decisionSeveritiesCSV = severityCSV
    }
    if decisionSearchScopeRaw != filters.scope.rawValue {
      decisionSearchScopeRaw = filters.scope.rawValue
    }
  }

}

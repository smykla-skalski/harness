import HarnessMonitorKit
import SwiftUI

enum WorkspaceDecisionFilterDefaults {
  static let severitiesKey = "harness.workspace.sidebar.severitiesCSV"
  static let searchScopeKey = "harness.workspace.sidebar.searchScope"

  static func reset(in defaults: UserDefaults = .standard) {
    defaults.set("", forKey: severitiesKey)
    defaults.set(DecisionsSidebarSearchScope.summary.rawValue, forKey: searchScopeKey)
  }
}

struct WorkspaceSidebar: View {
  let store: HarnessMonitorStore
  @Binding var selection: WorkspaceSelection
  @Binding var decisionFilters: DecisionsSidebarViewModel.FilterState
  let isStartupFocusParticipationEnabled: Bool
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

  @AppStorage(WorkspaceDecisionFilterDefaults.severitiesKey)
  private var decisionSeveritiesCSV = ""
  @AppStorage(WorkspaceDecisionFilterDefaults.searchScopeKey)
  private var decisionSearchScopeRaw = DecisionsSidebarSearchScope.summary.rawValue
  @State private var hasHydratedPersistedDecisionFilters = false
  @Environment(\.fontScale)
  private var fontScale

  var rowPadding: CGFloat {
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

  private var showsDecisionSearchChrome: Bool {
    selection.isDecisionRoute
  }

  var body: some View {
    searchableSidebarList
      .toolbar {
        WorkspaceSidebarDecisionFilterToolbarItem(
          selectedSeverities: decisionFilters.severities,
          isEnabled: decisionFiltersMenuEnabled,
          setSelectedSeverities: setDecisionSeverities
        )
      }
      .task {
        await hydratePersistedDecisionFiltersIfNeeded()
      }
      .onChange(of: decisionFilters) { _, newValue in
        syncPersistedDecisionPreferences(from: newValue)
      }
  }

  @ViewBuilder private var searchableSidebarList: some View {
    if isStartupFocusParticipationEnabled, showsDecisionSearchChrome {
      sidebarList
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
    } else {
      sidebarList
    }
  }

  private var sidebarList: some View {
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
                selection = .task(
                  sessionID: currentSessionID,
                  taskID: task.taskId
                )
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
  }

}

extension WorkspaceSidebar {
  fileprivate var persistedDecisionSeverities: Set<DecisionSeverity> {
    Set(
      decisionSeveritiesCSV
        .split(separator: ",")
        .compactMap { DecisionSeverity(rawValue: String($0)) }
    )
  }

  fileprivate func restorePersistedDecisionFiltersIfNeeded() {
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

  fileprivate func setDecisionSeverities(_ newValue: Set<DecisionSeverity>) {
    updateDecisionFilters(severities: newValue)
  }

  fileprivate func updateDecisionFilters(
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

  fileprivate func syncPersistedDecisionPreferences(
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

  @MainActor
  fileprivate func hydratePersistedDecisionFiltersIfNeeded() async {
    guard !hasHydratedPersistedDecisionFilters else {
      return
    }
    await Task.yield()
    guard !Task.isCancelled, !hasHydratedPersistedDecisionFilters else {
      return
    }
    hasHydratedPersistedDecisionFilters = true
    restorePersistedDecisionFiltersIfNeeded()
  }
}

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
  @State private var workspaceSearchQuery = ""
  @State private var searchFocusDispatcher = HarnessSidebarSearchFocusDispatcher()
  @State private var searchPresentationState = SidebarSearchPresentationState()
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

  private var workspaceSearchText: Binding<String> {
    Binding(
      get: { workspaceSearchQuery },
      set: { workspaceSearchQuery = $0 }
    )
  }

  var normalizedWorkspaceSearchQuery: String {
    workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var sidebarSearchText: Binding<String> {
    showsDecisionSearchChrome ? decisionSearchText : workspaceSearchText
  }

  private var decisionSearchScope: Binding<DecisionsSidebarSearchScope> {
    Binding(
      get: { decisionFilters.scope },
      set: { updateDecisionFilters(scope: $0) }
    )
  }

  private var searchPresentation: Binding<Bool> {
    Binding(
      get: { searchPresentationState.isPresented },
      set: { searchPresentationState.isPresented = $0 }
    )
  }

  private var decisionFiltersMenuEnabled: Bool {
    decisionScope.totalCount > 0 || !decisionFilters.severities.isEmpty
  }

  var activeTuis: [AgentTuiSnapshot] {
    agentTuis.filter { $0.status.isActive }
  }

  var inactiveTuis: [AgentTuiSnapshot] {
    agentTuis.filter { !$0.status.isActive }
  }

  var activeCodexRuns: [CodexRunSnapshot] {
    codexRuns.filter { $0.status.isActive }
  }

  var inactiveCodexRuns: [CodexRunSnapshot] {
    codexRuns.filter { !$0.status.isActive }
  }

  private var showsDecisionSearchChrome: Bool {
    selection.isDecisionRoute
  }

  private var sidebarSearchPrompt: Text {
    Text(showsDecisionSearchChrome ? "Search decisions" : "Search workspace")
  }

  private func handleSearchFocusRequest() {
    _ = searchPresentationState.requestPresentation(canPresent: true)
  }

  private func applyPendingSearchPresentationIfNeeded() {
    _ = searchPresentationState.applyPendingPresentationIfNeeded(
      canPresent: isStartupFocusParticipationEnabled
    )
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
      .focusedSceneValue(
        \.harnessSidebarSearchFocusAction,
        HarnessSidebarSearchFocus(
          isAvailable: isStartupFocusParticipationEnabled,
          menuLabel: showsDecisionSearchChrome ? .findInDecisions : .findGeneric,
          dispatcher: searchFocusDispatcher
        )
      )
      .task {
        searchFocusDispatcher.handler = { handleSearchFocusRequest() }
      }
      .onDisappear {
        searchFocusDispatcher.handler = nil
      }
      .task {
        await hydratePersistedDecisionFiltersIfNeeded()
      }
      .onChange(of: decisionFilters) { _, newValue in
        syncPersistedDecisionPreferences(from: newValue)
      }
      .onChange(of: isStartupFocusParticipationEnabled, initial: true) { _, _ in
        applyPendingSearchPresentationIfNeeded()
      }
      .onChange(of: showsDecisionSearchChrome) { _, _ in
        applyPendingSearchPresentationIfNeeded()
      }
  }

  @ViewBuilder private var searchableSidebarList: some View {
    let searchableList =
      sidebarList
      .listStyle(.sidebar)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .searchable(
        text: sidebarSearchText,
        isPresented: searchPresentation,
        placement: .sidebar,
        prompt: sidebarSearchPrompt
      )

    if showsDecisionSearchChrome {
      searchableList
        .searchScopes(decisionSearchScope, activation: .onSearchPresentation) {
          ForEach(DecisionsSidebarSearchScope.allCases) { scope in
            Text(scope.label).tag(scope)
          }
        }
    } else {
      searchableList
    }
  }

  private var sidebarList: some View {
    List(selection: selectionBinding) {
      if createRowMatchesWorkspaceSearch {
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
      }

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

      if !filteredExternalAgents.isEmpty {
        Section("Connected Agents") {
          ForEach(filteredExternalAgents) { agent in
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

      if !filteredActiveTuis.isEmpty {
        Section("Open Sessions") {
          ForEach(filteredActiveTuis) { tui in
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

      if !filteredInactiveTuis.isEmpty {
        Section("Past Sessions") {
          ForEach(filteredInactiveTuis) { tui in
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

      WorkspaceSidebarRunAndTaskSections(
        store: store,
        selection: $selection,
        rowPadding: rowPadding,
        currentSessionID: currentSessionID,
        codexTitlesByID: codexTitlesByID,
        activeCodexRuns: filteredActiveCodexRuns,
        inactiveCodexRuns: filteredInactiveCodexRuns,
        tasks: filteredTasks
      )
    }
    .listStyle(.sidebar)
    .workspaceBottomScrollContentMargin()
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

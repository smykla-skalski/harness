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
  @Binding var sidebarWidth: CGFloat
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
  let tasks: [WorkItem]

  @AppStorage(WorkspaceDecisionFilterDefaults.severitiesKey)
  private var decisionSeveritiesCSV = ""
  @AppStorage(WorkspaceDecisionFilterDefaults.searchScopeKey)
  private var decisionSearchScopeRaw = DecisionsSidebarSearchScope.summary.rawValue
  @State private var hasHydratedPersistedDecisionFilters = false
  @State private var workspaceSearchQuery = ""
  @State private var sidebarSearchQuery = ""
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

  private var selectedDecisionSeveritiesBinding: Binding<Set<DecisionSeverity>> {
    Binding(
      get: { decisionFilters.severities },
      set: { updateDecisionFilters(severities: $0) }
    )
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

  private var searchFocusAction: HarnessSidebarSearchFocus? {
    guard isStartupFocusParticipationEnabled else {
      return nil
    }
    return HarnessSidebarSearchFocus(
      isAvailable: true,
      menuLabel: showsDecisionSearchChrome ? .findInDecisions : .findGeneric,
      dispatcher: searchFocusDispatcher
    )
  }

  private var decisionFiltersMenuEnabled: Bool {
    decisionScope.totalCount > 0 || !decisionFilters.severities.isEmpty
  }

  private var currentRouteSearchQuery: String {
    showsDecisionSearchChrome ? decisionFilters.query : workspaceSearchQuery
  }

  var normalizedWorkspaceSearchQuery: String {
    workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

  private func syncSidebarSearchQueryFromCurrentRoute() {
    let currentRouteSearchQuery = currentRouteSearchQuery
    guard sidebarSearchQuery != currentRouteSearchQuery else {
      return
    }
    sidebarSearchQuery = currentRouteSearchQuery
  }

  private func handleSidebarSearchQueryChange(_ newValue: String) {
    if showsDecisionSearchChrome {
      guard decisionFilters.query != newValue else {
        return
      }
      updateDecisionFilters(query: newValue)
      return
    }

    guard workspaceSearchQuery != newValue else {
      return
    }
    workspaceSearchQuery = newValue
  }

  private func deferSidebarWidthCommit(_ newWidth: CGFloat) {
    Task { @MainActor in
      guard abs(sidebarWidth - newWidth) > 0.5 else {
        return
      }
      sidebarWidth = newWidth
    }
  }

  var body: some View {
    searchableSidebarList
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { newWidth in
        guard abs(sidebarWidth - newWidth) > 0.5 else {
          return
        }
        // Delay the binding write until after SwiftUI finishes this geometry
        // update pass; synchronous writes here trigger the live CGFloat fault.
        deferSidebarWidthCommit(newWidth)
      }
      .toolbar {
        WorkspaceSidebarDecisionFilterToolbarItem(
          selectedSeverities: selectedDecisionSeveritiesBinding,
          isEnabled: decisionFiltersMenuEnabled
        )
      }
      .harnessFocusedSceneValue(\.harnessSidebarSearchFocusAction, searchFocusAction)
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
        syncPersistedDecisionSettings(from: newValue)
      }
      .onChange(of: decisionFilters.query) { _, newValue in
        guard showsDecisionSearchChrome, sidebarSearchQuery != newValue else {
          return
        }
        sidebarSearchQuery = newValue
      }
      .onChange(of: sidebarSearchQuery) { _, newValue in
        handleSidebarSearchQueryChange(newValue)
      }
      .onChange(of: isStartupFocusParticipationEnabled, initial: true) { _, _ in
        syncSidebarSearchQueryFromCurrentRoute()
        applyPendingSearchPresentationIfNeeded()
      }
      .onChange(of: showsDecisionSearchChrome) { _, _ in
        syncSidebarSearchQueryFromCurrentRoute()
        applyPendingSearchPresentationIfNeeded()
      }
  }

  @ViewBuilder private var searchableSidebarList: some View {
    if showsDecisionSearchChrome {
      WorkspaceSidebarDecisionSearchContainer(
        content: sidebarList,
        searchText: $sidebarSearchQuery,
        searchPresentation: searchPresentation,
        decisionSearchScope: decisionSearchScope,
        prompt: sidebarSearchPrompt
      )
    } else {
      WorkspaceSidebarGenericSearchContainer(
        content: sidebarList,
        searchText: $sidebarSearchQuery,
        searchPresentation: searchPresentation,
        prompt: sidebarSearchPrompt
      )
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
        store: store,
        selection: $selection,
        decisionFilters: $decisionFilters,
        scope: decisionScope,
        currentSessionID: currentSessionID,
        currentSessionTitle: currentSessionTitle,
        fontScale: fontScale
      )

      if !filteredExternalAgents.isEmpty {
        Section("Connected Agents") {
          ForEach(filteredExternalAgents) { agent in
            WorkspaceSidebarExternalAgentRow(
              store: store,
              selection: $selection,
              agent: agent,
              currentSessionID: currentSessionID,
              rowPadding: rowPadding,
              attention: pendingDecisionAttention[agent.agentId]
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
      syncPersistedDecisionSettings(from: decisionFilters)
    }
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
      syncPersistedDecisionSettings(from: next)
      return
    }
    decisionFilters = next
    syncPersistedDecisionSettings(from: next)
  }

  fileprivate func syncPersistedDecisionSettings(
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

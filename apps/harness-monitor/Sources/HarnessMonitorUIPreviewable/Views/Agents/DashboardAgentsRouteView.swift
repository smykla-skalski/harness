import HarnessMonitorKit
import SwiftUI

struct DashboardAgentsRouteView: View {
  let store: HarnessMonitorStore
  let sessions: [SessionSummary]
  let history: GlobalWindowNavigationHistory
  let isRouteVisible: Bool
  let refreshesAutomatically: Bool
  let initialTerminalDetail: DashboardTerminalAgentDetail?
  let initialAcpDetail: DashboardAcpAgentDetail?
  let initialCodexDetail: DashboardCodexAgentDetail?
  @AppStorage(DashboardAgentSelectionDefaults.storageKey)
  private var persistedSelectionRaw = ""
  @State private var state: DashboardAgentsRouteState
  @State private var isPresentingTerminalCreate = false
  @State private var isPresentingAcpCreate = false
  @State private var isPresentingCodexCreate = false
  @State private var pendingNavigationRefreshRequestID: Int?
  @State private var pendingDecisionNavigationReadiness: DashboardDecisionNavigationReadiness?
  @State private var terminalCreateSessionID: String?

  init(
    store: HarnessMonitorStore,
    sessions: [SessionSummary],
    history: GlobalWindowNavigationHistory,
    isRouteVisible: Bool,
    refreshesAutomatically: Bool = true,
    initialState: DashboardAgentBrowserViewState = DashboardAgentBrowserViewState(),
    initialTerminalDetail: DashboardTerminalAgentDetail? = nil,
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil,
    selectionDefaults: UserDefaults = .standard
  ) {
    self.store = store
    self.sessions = sessions
    self.history = history
    self.isRouteVisible = isRouteVisible
    self.refreshesAutomatically = refreshesAutomatically
    self.initialTerminalDetail = initialTerminalDetail
    self.initialAcpDetail = initialAcpDetail
    self.initialCodexDetail = initialCodexDetail
    _persistedSelectionRaw = AppStorage(
      wrappedValue: "",
      DashboardAgentSelectionDefaults.storageKey,
      store: selectionDefaults
    )
    _state = State(initialValue: DashboardAgentsRouteState(viewState: initialState))
  }

  private var currentSelection: DashboardAgentsSelection? {
    DashboardAgentsSelection(rawValue: persistedSelectionRaw)
  }

  var stateValue: DashboardAgentsRouteState { state }

  var persistedSelectionRawValue: String {
    get { persistedSelectionRaw }
    nonmutating set { persistedSelectionRaw = newValue }
  }

  var pendingNavigationRefreshRequestIDValue: Int? {
    get { pendingNavigationRefreshRequestID }
    nonmutating set { pendingNavigationRefreshRequestID = newValue }
  }

  var pendingDecisionNavigationReadinessValue: DashboardDecisionNavigationReadiness? {
    get { pendingDecisionNavigationReadiness }
    nonmutating set { pendingDecisionNavigationReadiness = newValue }
  }

  @ViewBuilder
  private func detailPane(_ resolution: DashboardDecisionResolution) -> some View {
    switch currentSelection {
    case .globalDecisions:
      if resolution.unattributedItems.isEmpty {
        agentDetail(nil, decisions: [])
      } else {
        DashboardGlobalDecisionsDetail(store: store, items: resolution.unattributedItems)
      }
    case .workspaceDecisions(let workspaceID):
      if let bucket = resolution.workspaceBuckets.first(where: {
        $0.workspace.identity == workspaceID
      }) {
        DashboardWorkspaceDecisionsDetail(store: store, bucket: bucket)
      } else {
        agentDetail(nil, decisions: [])
      }
    case .agent(let identity):
      agentDetail(
        state.viewState.agents.first { $0.identity == identity },
        decisions: resolution.itemsByAgent[identity] ?? []
      )
    case nil:
      agentDetail(nil, decisions: [])
    }
  }

  private func agentDetail(
    _ agent: DashboardAgentSummary?,
    decisions: [DashboardDecisionItem]
  ) -> some View {
    DashboardAgentDetailPane(
      store: store,
      agent: agent,
      decisions: decisions,
      loadsTerminalDetailAutomatically: refreshesAutomatically,
      loadsAcpDetailAutomatically: refreshesAutomatically,
      loadsCodexDetailAutomatically: refreshesAutomatically,
      initialTerminalDetail: initialTerminalDetail,
      initialAcpDetail: initialAcpDetail,
      initialCodexDetail: initialCodexDetail,
      onTerminalMembershipRemoved: { requestRefresh(force: true) }
    )
  }

  private var selectionBinding: Binding<DashboardAgentsSelection?> {
    Binding(
      get: { currentSelection },
      set: { selection in
        let rawValue = selection?.rawValue ?? ""
        guard persistedSelectionRaw != rawValue else { return }
        persistedSelectionRaw = rawValue
        if let identity = selection?.agentIdentity {
          history.recordDashboardAgentSelection(identity)
        }
      }
    )
  }

  private var refreshContext: DashboardAgentsRefreshContext {
    DashboardAgentsRefreshContext(
      isVisible: isRouteVisible,
      connection: store.connectionState.refreshIdentity,
      sessionIDs: sessions.map(\.sessionId).sorted()
    )
  }

  var body: some View {
    let resolution = store.dashboardDecisionResolution(agents: state.viewState.agents)
    VStack(spacing: 0) {
      DashboardAgentsRouteHeader(
        countText: agentCountText(resolution),
        sourceLabel: sourceLabel,
        isLoading: state.viewState.isLoading,
        canCreateAgent: !sessions.isEmpty,
        createTerminalAgent: {
          terminalCreateSessionID = nil
          isPresentingTerminalCreate = true
        },
        createCodexAgent: { isPresentingCodexCreate = true },
        createAcpAgent: { isPresentingAcpCreate = true },
        refresh: requestManualRefresh
      )
      Divider()
      if state.viewState.presentsAsFullWidthState(
        hasDecisionDestinations: resolution.hasDecisionDestinations
      ) {
        DashboardAgentsListPane(
          state: state.viewState,
          selection: selectionBinding,
          decisionSummaries: resolution.summaryByAgent,
          workspaceBuckets: resolution.workspaceBuckets,
          unattributedItems: resolution.unattributedItems
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        DashboardAgentsIssueBanner(state: state.viewState)
        HSplitView {
          DashboardAgentsListPane(
            state: state.viewState,
            selection: selectionBinding,
            decisionSummaries: resolution.summaryByAgent,
            workspaceBuckets: resolution.workspaceBuckets,
            unattributedItems: resolution.unattributedItems
          )
          .frame(minWidth: 250, idealWidth: 310, maxWidth: 390)

          detailPane(resolution)
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .scaledFont(.body)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentsRoot)
    .onChange(of: state.viewState.agents, initial: true) {
      reconcileSelection()
      applyPendingHistoryRestoreIfNeeded()
    }
    .onChange(of: state.viewState.isLoading) { _, isLoading in
      if !isLoading {
        applyPendingHistoryRestoreIfNeeded()
      }
    }
    .onChange(of: sessions.map(\.sessionId)) {
      applyPendingHistoryRestoreIfNeeded()
    }
    .onChange(of: store.lastRefreshTimings?.recordedAt) {
      applyPendingHistoryRestoreIfNeeded()
    }
    .task(id: refreshContext) {
      guard refreshesAutomatically, isRouteVisible else { return }
      requestRefresh(force: true)
    }
    .task(id: isRouteVisible) {
      guard refreshesAutomatically, isRouteVisible else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          return
        }
        requestRefresh(force: false, presentation: .background)
      }
    }
    .task(id: history.pendingDashboardAgentsRestoreRequest?.requestID) {
      applyPendingHistoryRestoreIfNeeded()
    }
    .onChange(of: store.supervisorDecisionRefreshTick) {
      applyPendingHistoryRestoreIfNeeded()
    }
    .sheet(isPresented: $isPresentingTerminalCreate) {
      DashboardTerminalAgentCreateSheet(
        store: store,
        sessions: terminalCreateSessions,
        onCreated: selectCreatedTerminalAgent,
        onStartFailed: { requestRefresh(force: true) }
      )
    }
    .sheet(isPresented: $isPresentingAcpCreate) {
      DashboardAcpAgentCreateSheet(
        store: store,
        sessions: sessions,
        onCreated: selectCreatedAcpAgent
      )
    }
    .sheet(isPresented: $isPresentingCodexCreate) {
      DashboardCodexAgentCreateSheet(
        store: store,
        sessions: sessions,
        onCreated: selectCreatedCodexAgent
      )
    }
  }

  private func agentCountText(_ resolution: DashboardDecisionResolution) -> String {
    let count = state.viewState.agents.count
    let agentText = count == 1 ? "1 agent" : "\(count) agents"
    let agentWorkspaceIDs = state.viewState.groups.map(\.id)
    let decisionWorkspaceIDs = resolution.workspaceBuckets.map(\.id)
    let workspaceCount = Set(agentWorkspaceIDs + decisionWorkspaceIDs).count
    let workspaceText = workspaceCount == 1 ? "1 workspace" : "\(workspaceCount) workspaces"
    return "\(agentText) across \(workspaceText)"
  }

  private var sourceLabel: String? {
    guard !state.viewState.presentsAsFullWidthState else { return nil }
    guard let source = state.viewState.source else { return nil }
    return switch source {
    case .live: "Live"
    case .mixed: "Live + cached"
    case .cache: "Cached"
    }
  }

  private func requestManualRefresh() {
    requestRefresh(force: true)
  }

  private func selectCreatedAcpAgent(
    _ snapshot: AcpAgentSnapshot,
    _ session: SessionSummary
  ) {
    let identity = DashboardAgentIdentity(
      workspace: DashboardAgentWorkspaceIdentity(
        projectID: session.projectId,
        checkoutID: session.checkoutId
      ),
      runtimeKind: .acp,
      managedAgentID: snapshot.managedAgentID
    )
    persistedSelectionRaw = identity.selectionRawValue
    history.recordDashboardAgentSelection(identity)
    requestRefresh(force: true)
  }

  private func selectCreatedTerminalAgent(
    _ snapshot: AgentTuiSnapshot,
    _ session: SessionSummary
  ) {
    let identity = DashboardAgentIdentity(
      workspace: DashboardAgentWorkspaceIdentity(
        projectID: session.projectId,
        checkoutID: session.checkoutId
      ),
      runtimeKind: .terminal,
      managedAgentID: snapshot.managedAgentID
    )
    persistedSelectionRaw = identity.selectionRawValue
    history.recordDashboardAgentSelection(identity)
    requestRefresh(force: true)
  }

  private func selectCreatedCodexAgent(
    _ snapshot: CodexRunSnapshot,
    _ session: SessionSummary
  ) {
    let identity = DashboardAgentIdentity(
      workspace: DashboardAgentWorkspaceIdentity(
        projectID: session.projectId,
        checkoutID: session.checkoutId
      ),
      runtimeKind: .codex,
      managedAgentID: snapshot.managedAgentID
    )
    persistedSelectionRaw = identity.selectionRawValue
    history.recordDashboardAgentSelection(identity)
    requestRefresh(force: true)
  }

  func requestRefresh(
    force: Bool,
    presentation: DashboardAgentsLoadPresentation = .foreground
  ) {
    guard
      isRouteVisible,
      let generation = state.beginLoad(force: force, presentation: presentation)
    else { return }
    let sessionsSnapshot = sessions
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading Dashboard agents") {
        let cached = await store.cachedDashboardAgents(sessions: sessionsSnapshot)
        await state.adoptCache(cached, generation: generation)
        let result = await store.refreshDashboardAgents(
          sessions: sessionsSnapshot,
          cachedAgents: cached.agents
        )
        await state.finishLoad(result, generation: generation)
      }
    )
  }

  func presentTerminalCreation(sessionID: String) {
    terminalCreateSessionID = sessionID
    isPresentingTerminalCreate = true
  }

  var sessionCatalogIsReadyForNavigation: Bool {
    if store.lastRefreshTimings != nil { return true }
    switch store.sessionDataAvailability {
    case .live:
      return false
    case .persisted, .unavailable:
      return true
    }
  }

  private var terminalCreateSessions: [SessionSummary] {
    guard
      let terminalCreateSessionID,
      let preferred = sessions.first(where: { $0.sessionId == terminalCreateSessionID })
    else { return sessions }
    return [preferred] + sessions.filter { $0.sessionId != terminalCreateSessionID }
  }

  private func reconcileSelection() {
    let agents = state.viewState.agents
    switch currentSelection {
    case .agent(let identity):
      if agents.contains(where: { $0.identity == identity }) { return }
    case .workspaceDecisions:
      // A bucket selection stays put across agent updates; the detail pane falls back on its own
      // if the bucket clears, without stealing focus back to an agent.
      return
    case .globalDecisions:
      return
    case nil:
      break
    }
    guard let first = agents.first else { return }
    persistedSelectionRaw = first.identity.selectionRawValue
  }

}

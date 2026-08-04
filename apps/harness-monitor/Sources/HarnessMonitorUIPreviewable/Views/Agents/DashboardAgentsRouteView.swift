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
      header(resolution)
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
    .scaledFont(.body)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentsRoot)
    .onChange(of: state.viewState.agents, initial: true) {
      reconcileSelection()
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
        requestRefresh(force: false)
      }
    }
    .task(id: history.pendingDashboardAgentsRestoreRequest?.requestID) {
      applyPendingHistoryRestoreIfNeeded()
    }
    .sheet(isPresented: $isPresentingTerminalCreate) {
      DashboardTerminalAgentCreateSheet(
        store: store,
        sessions: sessions,
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

  private func header(_ resolution: DashboardDecisionResolution) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Agents")
          .scaledFont(.title3.weight(.semibold))
        Text(agentCountText(resolution))
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        isPresentingTerminalCreate = true
      } label: {
        Label("New terminal agent", systemImage: "plus")
      }
      .disabled(sessions.isEmpty)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardTerminalCreateButton)
      Button {
        isPresentingCodexCreate = true
      } label: {
        Label("New Codex agent", systemImage: "plus")
      }
      .disabled(sessions.isEmpty)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardCodexCreateButton)
      Button {
        isPresentingAcpCreate = true
      } label: {
        Label("New ACP agent", systemImage: "plus")
      }
      .disabled(sessions.isEmpty)
      if let sourceLabel {
        Text(sourceLabel)
          .scaledFont(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.quaternary, in: Capsule())
      }
      Button {
        requestManualRefresh()
      } label: {
        if state.viewState.isLoading {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("Refresh Agents", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
      }
      .buttonStyle(.borderless)
      .help("Refresh agents")
      .accessibilityLabel("Refresh agents")
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentsRefreshButton)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 54)
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

  private func requestRefresh(force: Bool) {
    guard isRouteVisible, let generation = state.beginLoad(force: force) else { return }
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
    history.recordDashboardAgentSelection(first.identity)
  }

  private func applyPendingHistoryRestoreIfNeeded() {
    guard let request = history.pendingDashboardAgentsRestoreRequest else { return }
    persistedSelectionRaw = request.identity.selectionRawValue
    history.finishDashboardAgentsRestoreRequest(request.requestID)
  }
}

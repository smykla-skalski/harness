import HarnessMonitorKit
import SwiftUI

struct DashboardAgentsRouteView: View {
  let store: HarnessMonitorStore
  let sessions: [SessionSummary]
  let history: GlobalWindowNavigationHistory
  let isRouteVisible: Bool
  let refreshesAutomatically: Bool
  let initialAcpDetail: DashboardAcpAgentDetail?
  let initialCodexDetail: DashboardCodexAgentDetail?
  @AppStorage(DashboardAgentSelectionDefaults.storageKey)
  private var persistedSelectionRaw = ""
  @State private var state: DashboardAgentsRouteState
  @State private var isPresentingAcpCreate = false
  @State private var isPresentingCodexCreate = false

  init(
    store: HarnessMonitorStore,
    sessions: [SessionSummary],
    history: GlobalWindowNavigationHistory,
    isRouteVisible: Bool,
    refreshesAutomatically: Bool = true,
    initialState: DashboardAgentBrowserViewState = DashboardAgentBrowserViewState(),
    initialAcpDetail: DashboardAcpAgentDetail? = nil,
    initialCodexDetail: DashboardCodexAgentDetail? = nil,
    selectionDefaults: UserDefaults = .standard
  ) {
    self.store = store
    self.sessions = sessions
    self.history = history
    self.isRouteVisible = isRouteVisible
    self.refreshesAutomatically = refreshesAutomatically
    self.initialAcpDetail = initialAcpDetail
    self.initialCodexDetail = initialCodexDetail
    _persistedSelectionRaw = AppStorage(
      wrappedValue: "",
      DashboardAgentSelectionDefaults.storageKey,
      store: selectionDefaults
    )
    _state = State(initialValue: DashboardAgentsRouteState(viewState: initialState))
  }

  private var selectedIdentity: DashboardAgentIdentity? {
    DashboardAgentIdentity(selectionRawValue: persistedSelectionRaw)
  }

  private var selectedAgent: DashboardAgentSummary? {
    guard let selectedIdentity else { return nil }
    return state.viewState.agents.first { $0.identity == selectedIdentity }
  }

  private var selectionBinding: Binding<DashboardAgentIdentity?> {
    Binding(
      get: { selectedIdentity },
      set: { identity in
        let rawValue = identity?.selectionRawValue ?? ""
        guard persistedSelectionRaw != rawValue else { return }
        persistedSelectionRaw = rawValue
        if let identity {
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
    VStack(spacing: 0) {
      header
      Divider()
      if state.viewState.presentsAsFullWidthState {
        DashboardAgentsListPane(
          state: state.viewState,
          selection: selectionBinding
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        DashboardAgentsIssueBanner(state: state.viewState)
        HSplitView {
          DashboardAgentsListPane(
            state: state.viewState,
            selection: selectionBinding
          )
          .frame(minWidth: 250, idealWidth: 310, maxWidth: 390)

          DashboardAgentDetailPane(
            store: store,
            agent: selectedAgent,
            loadsAcpDetailAutomatically: refreshesAutomatically,
            loadsCodexDetailAutomatically: refreshesAutomatically,
            initialAcpDetail: initialAcpDetail,
            initialCodexDetail: initialCodexDetail
          )
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

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Agents")
          .scaledFont(.title3.weight(.semibold))
        Text(agentCountText)
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
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

  private var agentCountText: String {
    let count = state.viewState.agents.count
    let agentText = count == 1 ? "1 agent" : "\(count) agents"
    let workspaceCount = state.viewState.groups.count
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
    guard !agents.isEmpty else { return }
    if let selectedIdentity, agents.contains(where: { $0.identity == selectedIdentity }) {
      return
    }
    persistedSelectionRaw = agents[0].identity.selectionRawValue
    history.recordDashboardAgentSelection(agents[0].identity)
  }

  private func applyPendingHistoryRestoreIfNeeded() {
    guard let request = history.pendingDashboardAgentsRestoreRequest else { return }
    persistedSelectionRaw = request.identity.selectionRawValue
    history.finishDashboardAgentsRestoreRequest(request.requestID)
  }
}

private struct DashboardAgentsIssueBanner: View {
  let state: DashboardAgentBrowserViewState

  var body: some View {
    if let issue = state.issue {
      HStack(spacing: 8) {
        Image(systemName: issue.systemImage)
        Text(issue.message(hasCachedAgents: !state.agents.isEmpty))
          .lineLimit(2)
        Spacer()
      }
      .scaledFont(.callout)
      .foregroundStyle(issue.tint)
      .padding(.horizontal, 16)
      .padding(.vertical, 9)
      .background(issue.tint.opacity(0.08))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAgentsLoadState)
    }
  }
}

extension DashboardAgentLoadIssue {
  fileprivate var systemImage: String {
    switch self {
    case .offline: "wifi.slash"
    case .requestFailure: "exclamationmark.triangle"
    }
  }

  fileprivate var tint: Color {
    switch self {
    case .offline: HarnessMonitorTheme.caution
    case .requestFailure: HarnessMonitorTheme.danger
    }
  }

  fileprivate func message(hasCachedAgents: Bool) -> String {
    switch self {
    case .offline(let reason):
      hasCachedAgents
        ? "Offline — showing cached agents — \(reason.withoutTrailingPeriod)"
        : "Offline — no cached agents available — \(reason.withoutTrailingPeriod)"
    case .requestFailure(let message):
      hasCachedAgents
        ? "Refresh failed — unaffected workspaces remain visible — \(message.withoutTrailingPeriod)"
        : "Agent request failed — \(message.withoutTrailingPeriod)"
    }
  }
}

private struct DashboardAgentsRefreshContext: Hashable {
  let isVisible: Bool
  let connection: String
  let sessionIDs: [String]
}

extension HarnessMonitorStore.ConnectionState {
  fileprivate var refreshIdentity: String {
    switch self {
    case .idle: "idle"
    case .connecting: "connecting"
    case .online: "online"
    case .offline(let message): "offline:\(message)"
    }
  }
}

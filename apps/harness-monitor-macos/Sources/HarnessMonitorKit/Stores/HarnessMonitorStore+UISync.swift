import Foundation

extension HarnessMonitorStore {
  enum UISyncArea: Hashable {
    case content
    case sidebar
    case inspector
  }
}

extension HarnessMonitorStore {
  func withUISyncBatch(_ body: () -> Void) {
    let wasApplyingBatch = isApplyingUISyncBatch
    isApplyingUISyncBatch = true
    body()
    isApplyingUISyncBatch = wasApplyingBatch
    if !wasApplyingBatch {
      flushPendingUISync()
    }
  }

  func bindUISlices() {
    connection.onChanged = { [weak self] change in
      switch change {
      case .shellState:
        self?.scheduleUISync([.content, .sidebar, .inspector])
      case .metrics:
        self?.scheduleUISync([.sidebar])
      }
    }
    selection.onChanged = { [weak self] change in
      switch change {
      case .selectedSessionID:
        self?.scheduleUISync([.content, .sidebar, .inspector])
      case .selectedSession:
        self?.scheduleUISync([.content, .inspector])
      case .timeline:
        self?.scheduleUISync([.content])
      case .inspectorSelection, .actionActorID:
        self?.scheduleUISync([.inspector])
      case .selectionLoading, .extensionsLoading:
        self?.scheduleUISync([.content])
      case .sessionAction:
        self?.scheduleUISync([.content, .inspector])
      }
    }
    userData.onChanged = { [weak self] in
      self?.scheduleUISync([.sidebar])
    }
    sessionIndex.onChanged = { [weak self] change in
      switch change {
      case .data:
        self?.scheduleUISync([.content, .sidebar, .inspector])
      case .projection:
        self?.scheduleUISync([.sidebar])
      }
    }
  }

  func scheduleUISync(_ area: UISyncArea) {
    scheduleUISync([area])
  }

  func scheduleUISync(_ areas: Set<UISyncArea>) {
    pendingUISyncAreas.formUnion(areas)
    if !isApplyingUISyncBatch {
      flushPendingUISync()
    }
  }

  func syncAllUI() {
    syncUI([.content, .sidebar, .inspector])
  }

  private func flushPendingUISync() {
    guard !pendingUISyncAreas.isEmpty else {
      return
    }

    let areas = pendingUISyncAreas
    pendingUISyncAreas.removeAll()
    syncUI(areas)
  }

  private func syncUI(_ areas: Set<UISyncArea>) {
    if areas.contains(.content) {
      syncContentUI()
    }
    if areas.contains(.sidebar) {
      syncSidebarUI()
    }
    if areas.contains(.inspector) {
      syncInspectorUI()
    }
  }

  private func syncContentUI() {
    let selectedDetail = matchedSelectedDetail()
    let selectedSessionSummary = sessionIndex.sessionSummary(
      for: selection.selectedSessionID
    )
    let toolbarMetrics = ToolbarMetricsState(
      projectCount: daemonStatus?.projectCount ?? sessionIndex.projects.count,
      worktreeCount: daemonStatus?.worktreeCount
        ?? sessionIndex.projects.reduce(0) { $0 + $1.worktrees.count },
      sessionCount: daemonStatus?.sessionCount ?? sessionIndex.sessions.count,
      openWorkCount: sessionIndex.totalOpenWorkCount,
      blockedCount: sessionIndex.totalBlockedCount
    )

    assign(selection.selectedSessionID, to: \.selectedSessionID, on: contentUI)
    assign(selectedDetail, to: \.selectedDetail, on: contentUI)
    assign(selectedSessionSummary, to: \.selectedSessionSummary, on: contentUI)
    assign(selection.timeline, to: \.timeline, on: contentUI)
    assign(
      selectedDetail != nil || selectedSessionSummary != nil ? "Cockpit" : "Dashboard",
      to: \.windowTitle,
      on: contentUI
    )
    assign(persistenceError, to: \.persistenceError, on: contentUI)
    assign(sessionDataAvailability, to: \.sessionDataAvailability, on: contentUI)
    assign(
      selectedDetail?.session.status ?? selectedSessionSummary?.status,
      to: \.sessionStatus,
      on: contentUI
    )
    assign(toolbarMetrics, to: \.toolbarMetrics, on: contentUI)
    assign(
      resolveStatusMessages(sessionCount: toolbarMetrics.sessionCount),
      to: \.statusMessages,
      on: contentUI
    )
    assign(resolveDaemonIndicatorState(), to: \.daemonIndicator, on: contentUI)
    assign(
      daemonStatus?.launchAgent.installed == true,
      to: \.isLaunchAgentInstalled,
      on: contentUI
    )
    assign(isBusy, to: \.isBusy, on: contentUI)
    assign(canNavigateBack, to: \.canNavigateBack, on: contentUI)
    assign(canNavigateForward, to: \.canNavigateForward, on: contentUI)
    assign(connectionState, to: \.connectionState, on: contentUI)
    assign(isSessionReadOnly, to: \.isSessionReadOnly, on: contentUI)
    assign(isSessionActionInFlight, to: \.isSessionActionInFlight, on: contentUI)
    assign(isRefreshing, to: \.isRefreshing, on: contentUI)
    assign(isSelectionLoading, to: \.isSelectionLoading, on: contentUI)
    assign(isExtensionsLoading, to: \.isExtensionsLoading, on: contentUI)
    assign(lastAction, to: \.lastAction, on: contentUI)
    assign(pendingConfirmation, to: \.pendingConfirmation, on: contentUI)
    assign(presentedSheet, to: \.presentedSheet, on: contentUI)
    assign(sleepPreventionEnabled, to: \.sleepPreventionEnabled, on: contentUI)
  }

  private func syncSidebarUI() {
    assign(connectionState, to: \.connectionState, on: sidebarUI)
    assign(isBusy, to: \.isBusy, on: sidebarUI)
    assign(isRefreshing, to: \.isRefreshing, on: sidebarUI)
    assign(
      daemonStatus?.launchAgent.installed == true,
      to: \.isLaunchAgentInstalled,
      on: sidebarUI
    )
    assign(connectionMetrics, to: \.connectionMetrics, on: sidebarUI)
    assign(selection.selectedSessionID, to: \.selectedSessionID, on: sidebarUI)
    assign(isPersistenceAvailable, to: \.isPersistenceAvailable, on: sidebarUI)
    assign(userData.bookmarkedSessionIds, to: \.bookmarkedSessionIds, on: sidebarUI)
    assign(resolveSidebarEmptyState(), to: \.emptyState, on: sidebarUI)
    assign(resolveSidebarFilterSummary(), to: \.filterSummary, on: sidebarUI)
  }

  private func syncInspectorUI() {
    let selectedDetail = matchedSelectedDetail()
    let selectedSessionSummary = sessionIndex.sessionSummary(
      for: selection.selectedSessionID
    )

    assign(
      HarnessMonitorStore.InspectorPrimaryContentState(
        selectedSession: selectedDetail,
        selectedSessionSummary: selectedSessionSummary,
        inspectorSelection: selection.inspectorSelection,
        isPersistenceAvailable: isPersistenceAvailable
      ),
      to: \.primaryContent,
      on: inspectorUI
    )
    assign(
      resolveInspectorActionContext(detail: selectedDetail),
      to: \.actionContext,
      on: inspectorUI
    )
  }

  private func matchedSelectedDetail() -> SessionDetail? {
    guard let sessionID = selection.selectedSessionID,
      let detail = selection.selectedSession,
      detail.session.sessionId == sessionID
    else {
      return nil
    }
    return detail
  }

  private func resolveStatusMessages(
    sessionCount: Int
  ) -> [StatusMessageState] {
    var messages: [StatusMessageState] = []

    if connectionState == .connecting {
      messages.append(
        .init(
          id: "loading.connecting",
          text: "Connecting to the control plane",
          systemImage: "network",
          tone: .caution
        )
      )
    }
    if isRefreshing {
      messages.append(
        .init(
          id: "loading.refreshing",
          text: "Refreshing session index",
          systemImage: "arrow.trianglehead.2.clockwise",
          tone: .caution
        )
      )
    }
    if isSelectionLoading {
      messages.append(
        .init(
          id: "loading.session",
          text: "Loading session detail",
          systemImage: "doc.text.magnifyingglass",
          tone: .caution
        )
      )
    }
    if isExtensionsLoading {
      messages.append(
        .init(
          id: "loading.extensions",
          text: "Loading observers and signals",
          systemImage: "antenna.radiowaves.left.and.right",
          tone: .caution
        )
      )
    }

    messages.append(contentsOf: [
      .init(
        id: "status.running",
        text: "Running Harness Monitor",
        systemImage: "gearshape.fill",
        tone: .info
      ),
      .init(
        id: "status.sessions",
        text: "\(sessionCount) sessions active",
        systemImage: "antenna.radiowaves.left.and.right",
        tone: .success
      ),
      .init(
        id: "status.daemon",
        text: "Daemon connected",
        systemImage: "checkmark.circle.fill",
        tone: .success
      ),
    ])

    return messages
  }

  private func resolveDaemonIndicatorState() -> DaemonIndicatorState {
    guard connectionState == .online else {
      return .offline
    }
    if daemonStatus?.launchAgent.installed == true {
      return .launchdConnected
    }
    return .manualConnected
  }

  private func resolveSidebarEmptyState() -> SidebarEmptyState {
    if sessionIndex.sessions.isEmpty {
      return .noSessions
    }
    if sessionIndex.groupedSessions.isEmpty {
      return .noMatches
    }
    return .sessionsAvailable
  }

  private func resolveSidebarFilterSummary() -> SidebarFilterSummaryState {
    let isFiltered =
      !sessionIndex.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || sessionIndex.sessionFilter != .active
      || sessionIndex.sessionFocusFilter != .all

    if isFiltered {
      return SidebarFilterSummaryState(
        activeFilterSummary:
          "\(sessionIndex.filteredSessionCount) visible of \(sessionIndex.sessions.count)",
        isFiltered: true
      )
    }

    return SidebarFilterSummaryState(
      activeFilterSummary: "\(sessionIndex.sessions.count) indexed",
      isFiltered: false
    )
  }

  private func resolveInspectorActionContext(
    detail: SessionDetail?
  ) -> HarnessMonitorStore.InspectorActionContext? {
    guard let detail else {
      return nil
    }

    let selectedTask: WorkItem?
    if case .task(let taskID) = selection.inspectorSelection {
      selectedTask = detail.tasks.first(where: { $0.taskId == taskID })
    } else {
      selectedTask = nil
    }

    let selectedAgent: AgentRegistration?
    if case .agent(let agentID) = selection.inspectorSelection {
      selectedAgent = detail.agents.first(where: { $0.agentId == agentID })
    } else {
      selectedAgent = nil
    }

    let selectedObserver: ObserverSummary?
    if case .observer = selection.inspectorSelection {
      selectedObserver = detail.observer
    } else {
      selectedObserver = nil
    }

    return HarnessMonitorStore.InspectorActionContext(
      detail: detail,
      selectedTask: selectedTask,
      selectedAgent: selectedAgent,
      selectedObserver: selectedObserver,
      isPersistenceAvailable: isPersistenceAvailable,
      availableActionActors: detail.agents.filter { $0.status == .active },
      selectedActionActorID: resolvedActionActor() ?? "",
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight,
      lastAction: lastAction,
      lastError: lastError
    )
  }

  func assign<Root: AnyObject, Value: Equatable>(
    _ value: Value,
    to keyPath: ReferenceWritableKeyPath<Root, Value>,
    on root: Root
  ) {
    guard root[keyPath: keyPath] != value else {
      return
    }
    root[keyPath: keyPath] = value
  }
}

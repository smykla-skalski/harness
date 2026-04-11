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
        self?.scheduleUISync([.content])
      case .projection:
        break
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
    let selectedDetail = selection.matchedSelectedSession
    let selectedSessionSummary = sessionIndex.sessionSummary(
      for: selection.selectedSessionID
    )
    let contentShell = contentUI.shell
    let contentToolbar = contentUI.toolbar
    let contentChrome = contentUI.chrome
    let contentSession = contentUI.session
    let contentSessionDetail = contentUI.sessionDetail
    let contentDashboard = contentUI.dashboard
    let toolbarMetrics = ToolbarMetricsState(
      projectCount: daemonStatus?.projectCount ?? sessionIndex.projects.count,
      worktreeCount: daemonStatus?.worktreeCount
        ?? sessionIndex.projects.reduce(0) { $0 + $1.worktrees.count },
      sessionCount: daemonStatus?.sessionCount ?? sessionIndex.sessions.count,
      openWorkCount: sessionIndex.totalOpenWorkCount,
      blockedCount: sessionIndex.totalBlockedCount
    )
    let sessionDragActive = contentSession.isTaskDragActive

    contentShell.apply(
      ContentShellState(
        selectedSessionID: selection.selectedSessionID,
        windowTitle: selectedDetail != nil || selectedSessionSummary != nil
          ? "Cockpit" : "Dashboard",
        connectionState: connectionState,
        isRefreshing: isRefreshing,
        isSelectionLoading: isSelectionLoading,
        isExtensionsLoading: isExtensionsLoading,
        lastAction: lastAction,
        pendingConfirmation: pendingConfirmation,
        presentedSheet: presentedSheet
      )
    )

    contentChrome.apply(
      ContentChromeState(
        persistenceError: persistenceError,
        sessionDataAvailability: sessionDataAvailability,
        sessionStatus: selectedDetail?.session.status ?? selectedSessionSummary?.status
      )
    )
    assign(
      toolbarMetrics,
      to: \.toolbarMetrics,
      on: contentToolbar
    )
    assign(
      resolveStatusMessages(sessionCount: toolbarMetrics.sessionCount),
      to: \.statusMessages,
      on: contentToolbar
    )
    assign(resolveDaemonIndicatorState(), to: \.daemonIndicator, on: contentToolbar)
    assign(canNavigateBack, to: \.canNavigateBack, on: contentToolbar)
    assign(canNavigateForward, to: \.canNavigateForward, on: contentToolbar)
    assign(isRefreshing, to: \.isRefreshing, on: contentToolbar)
    assign(sleepPreventionEnabled, to: \.sleepPreventionEnabled, on: contentToolbar)
    assign(connectionState, to: \.connectionState, on: contentToolbar)
    assign(isBusy, to: \.isBusy, on: contentToolbar)

    contentSessionDetail.apply(
      ContentSessionDetailState(
        selectedSessionDetail: selectedDetail,
        timeline: selection.timeline
      )
    )
    contentSession.apply(
      ContentSessionState(
        selectedSessionSummary: selectedSessionSummary,
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        isSelectionLoading: isSelectionLoading,
        isExtensionsLoading: isExtensionsLoading,
        lastAction: lastAction,
        isTaskDragActive: sessionDragActive
      )
    )

    contentDashboard.apply(
      ContentDashboardState(
        connectionState: connectionState,
        isBusy: isBusy,
        isRefreshing: isRefreshing,
        isLaunchAgentInstalled: daemonStatus?.launchAgent.installed == true
      )
    )
  }

  private func syncSidebarUI() {
    sidebarUI.apply(
      SidebarUIState(
        connectionMetrics: connectionMetrics,
        selectedSessionID: selection.selectedSessionID,
        isPersistenceAvailable: isPersistenceAvailable,
        bookmarkedSessionIds: userData.bookmarkedSessionIds,
        searchFocusRequest: sidebarUI.searchFocusRequest
      )
    )
  }

  private func syncInspectorUI() {
    let resolvedPrimaryContent = InspectorPrimaryContentState(
      selectedSession: selection.matchedSelectedSession,
      selectedSessionSummary: contentUI.session.selectedSessionSummary,
      inspectorSelection: selection.inspectorSelection,
      isPersistenceAvailable: isPersistenceAvailable
    )

    let resolvedActionContext = InspectorActionContext(
      detail: selection.matchedSelectedSession,
      inspectorSelection: selection.inspectorSelection,
      isPersistenceAvailable: isPersistenceAvailable,
      selectedActionActorID: resolvedActionActor() ?? "",
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight,
      lastAction: lastAction,
      lastError: lastError
    )
    inspectorUI.apply(
      InspectorUIState(
        isPersistenceAvailable: isPersistenceAvailable,
        selectedActionActorID: resolvedActionActor() ?? "",
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        lastAction: lastAction,
        lastError: lastError,
        primaryContent: resolvedPrimaryContent,
        actionContext: resolvedActionContext
      )
    )
  }

  private func resolveStatusMessages(
    sessionCount: Int
  ) -> [StatusMessageState] {
    var messages: [StatusMessageState] = []

    if !lastAction.isEmpty {
      messages.append(
        .init(
          id: "last-action",
          text: lastAction,
          systemImage: "checkmark.circle.fill",
          tone: .success
        )
      )
    }

    switch connectionState {
    case .connecting:
      messages.append(
        .init(
          id: "connecting",
          text: "Connecting to daemon",
          systemImage: "arrow.trianglehead.2.clockwise",
          tone: .caution
        )
      )
    case .offline(let reason):
      let offlineText =
        isShowingCachedData || persistedSessionCount > 0 || sessionCount > 0
        ? cachedDataStatusMessage
        : reason
      messages.append(
        .init(
          id: "offline",
          text: offlineText,
          systemImage: "wifi.slash",
          tone: .secondary
        )
      )
    case .online:
      if isRefreshing {
        messages.append(
          .init(
            id: "refreshing",
            text: "Refreshing sessions",
            systemImage: "arrow.clockwise",
            tone: .secondary
          )
        )
      }
    case .idle:
      break
    }

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

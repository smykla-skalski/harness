import Foundation

extension HarnessMonitorStore {
  enum UISyncArea: Hashable {
    case contentShell
    case contentToolbar
    case contentChrome
    case contentSession
    case contentSessionDetail
    case contentDashboard
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
        self?.scheduleUISync([
          .contentShell,
          .contentToolbar,
          .contentChrome,
          .contentSession,
          .contentDashboard,
          .inspector,
        ])
      case .metrics:
        self?.scheduleUISync([.sidebar])
      }
    }
    selection.onChanged = { [weak self] change in
      switch change {
      case .selectedSessionID:
        self?.scheduleUISync([
          .contentShell,
          .contentChrome,
          .contentSession,
          .sidebar,
          .inspector,
        ])
      case .selectedSession:
        self?.scheduleUISync([
          .contentChrome,
          .contentSessionDetail,
          .inspector,
        ])
      case .timeline:
        self?.scheduleUISync([.contentSessionDetail])
      case .inspectorSelection, .actionActorID:
        self?.scheduleUISync([.inspector])
      case .selectionLoading, .extensionsLoading:
        self?.scheduleUISync([.contentSession])
      case .sessionAction:
        self?.scheduleUISync([
          .contentToolbar,
          .contentSession,
          .contentDashboard,
          .inspector,
        ])
      case .inFlightActionID:
        self?.scheduleUISync([.inspector])
      }
    }
    userData.onChanged = { [weak self] in
      self?.scheduleUISync([.sidebar])
    }
    sessionIndex.onChanged = { [weak self] change in
      switch change {
      case .snapshot:
        self?.scheduleUISync([
          .contentToolbar,
          .contentChrome,
          .contentSession,
          .inspector,
        ])
      case .summaryProjection(let sessionID):
        var areas: Set<UISyncArea> = [.contentToolbar]
        if self?.selection.selectedSessionID == sessionID {
          areas.formUnion([.contentChrome, .contentSession, .inspector])
        }
        self?.scheduleUISync(areas)
      case .summaryMetadata(let sessionID):
        guard self?.selection.selectedSessionID == sessionID else {
          return
        }
        self?.scheduleUISync([.contentChrome, .contentSession, .inspector])
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
    syncUI([
      .contentShell,
      .contentToolbar,
      .contentChrome,
      .contentSession,
      .contentSessionDetail,
      .contentDashboard,
      .sidebar,
      .inspector,
    ])
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
    if areas.contains(.contentShell) {
      syncContentShellUI()
    }
    if areas.contains(.contentToolbar) {
      syncContentToolbarUI()
    }
    if areas.contains(.contentChrome) {
      syncContentChromeUI()
    }
    if areas.contains(.contentSession) {
      syncContentSessionUI()
    }
    if areas.contains(.contentSessionDetail) {
      syncContentSessionDetailUI()
    }
    if areas.contains(.contentDashboard) {
      syncContentDashboardUI()
    }
    if areas.contains(.sidebar) {
      syncSidebarUI()
    }
    if areas.contains(.inspector) {
      syncInspectorUI()
    }
    for area in areas {
      debugUISyncCounts[area, default: 0] += 1
    }
  }

  func debugUISyncCount(for area: UISyncArea) -> Int {
    debugUISyncCounts[area, default: 0]
  }

  func debugResetUISyncCounts() {
    debugUISyncCounts.removeAll(keepingCapacity: true)
  }

  private func syncContentShellUI() {
    let selectedDetail = selection.matchedSelectedSession
    let selectedSessionSummary = sessionIndex.sessionSummary(
      for: selection.selectedSessionID
    )

    contentUI.shell.apply(
      ContentShellState(
        selectedSessionID: selection.selectedSessionID,
        windowTitle: selectedDetail != nil || selectedSessionSummary != nil
          ? "Cockpit" : "Dashboard",
        connectionState: connectionState,
        pendingConfirmation: pendingConfirmation,
        presentedSheet: presentedSheet
      )
    )
  }

  private func syncContentToolbarUI() {
    let toolbarMetrics = ToolbarMetricsState(
      projectCount: daemonStatus?.projectCount ?? sessionIndex.projects.count,
      worktreeCount: daemonStatus?.worktreeCount
        ?? sessionIndex.projects.reduce(0) { $0 + $1.worktrees.count },
      sessionCount: daemonStatus?.sessionCount ?? sessionIndex.sessions.count,
      openWorkCount: sessionIndex.totalOpenWorkCount,
      blockedCount: sessionIndex.totalBlockedCount
    )
    assign(
      toolbarMetrics,
      to: \.toolbarMetrics,
      on: contentUI.toolbar
    )
    assign(
      resolveStatusMessages(sessionCount: toolbarMetrics.sessionCount),
      to: \.statusMessages,
      on: contentUI.toolbar
    )
    assign(resolveDaemonIndicatorState(), to: \.daemonIndicator, on: contentUI.toolbar)
    assign(canNavigateBack, to: \.canNavigateBack, on: contentUI.toolbar)
    assign(canNavigateForward, to: \.canNavigateForward, on: contentUI.toolbar)
    assign(isRefreshing, to: \.isRefreshing, on: contentUI.toolbar)
    assign(sleepPreventionEnabled, to: \.sleepPreventionEnabled, on: contentUI.toolbar)
    assign(connectionState, to: \.connectionState, on: contentUI.toolbar)
    assign(isBusy, to: \.isBusy, on: contentUI.toolbar)
  }

  private func syncContentChromeUI() {
    let selectedDetail = selection.matchedSelectedSession
    let selectedSessionSummary = sessionIndex.sessionSummary(
      for: selection.selectedSessionID
    )

    contentUI.chrome.apply(
      ContentChromeState(
        persistenceError: persistenceError,
        sessionDataAvailability: sessionDataAvailability,
        sessionStatus: selectedDetail?.session.status ?? selectedSessionSummary?.status
      )
    )
  }

  private func syncContentSessionUI() {
    let selectedSessionSummary = sessionIndex.sessionSummary(
      for: selection.selectedSessionID
    )

    contentUI.session.apply(
      ContentSessionState(
        selectedSessionSummary: selectedSessionSummary,
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        isSelectionLoading: isSelectionLoading,
        isExtensionsLoading: isExtensionsLoading,
        isTaskDragActive: contentUI.session.isTaskDragActive
      )
    )
  }

  private func syncContentSessionDetailUI() {
    contentUI.sessionDetail.apply(
      ContentSessionDetailState(
        selectedSessionDetail: selection.matchedSelectedSession,
        timeline: selection.timeline
      )
    )
  }

  private func syncContentDashboardUI() {
    contentUI.dashboard.apply(
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
    let selectedSessionSummary = sessionIndex.sessionSummary(
      for: selection.selectedSessionID
    )
    let resolvedPrimaryContent = InspectorPrimaryContentState(
      selectedSession: selection.matchedSelectedSession,
      selectedSessionSummary: selectedSessionSummary,
      inspectorSelection: selection.inspectorSelection,
      isPersistenceAvailable: isPersistenceAvailable
    )

    let resolvedActionContext = InspectorActionContext(
      detail: selection.matchedSelectedSession,
      inspectorSelection: selection.inspectorSelection,
      isPersistenceAvailable: isPersistenceAvailable,
      selectedActionActorID: resolvedActionActor() ?? "",
      isSessionReadOnly: isSessionReadOnly,
      isSessionActionInFlight: isSessionActionInFlight
    )
    inspectorUI.apply(
      InspectorUIState(
        isPersistenceAvailable: isPersistenceAvailable,
        selectedActionActorID: resolvedActionActor() ?? "",
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        primaryContent: resolvedPrimaryContent,
        actionContext: resolvedActionContext
      )
    )
  }

  private func resolveStatusMessages(
    sessionCount: Int
  ) -> [StatusMessageState] {
    var messages: [StatusMessageState] = []

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

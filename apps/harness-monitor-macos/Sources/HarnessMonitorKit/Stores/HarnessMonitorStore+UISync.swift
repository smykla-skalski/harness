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
      self?.handleConnectionChange(change)
    }
    selection.onChanged = { [weak self] change in
      self?.handleSelectionChange(change)
    }
    userData.onChanged = { [weak self] in
      self?.scheduleUISync([.sidebar])
    }
    sessionIndex.onChanged = { [weak self] change in
      self?.handleSessionIndexChange(change)
    }
  }

  private func handleConnectionChange(_ change: ConnectionSlice.Change) {
    switch change {
    case .connectionState:
      scheduleUISync([
        .contentShell,
        .contentToolbar,
        .contentChrome,
        .contentSession,
        .contentDashboard,
        .inspector,
      ])
    case .daemonStatus:
      scheduleUISync([.contentToolbar, .contentDashboard])
    case .refreshState, .daemonActivity:
      scheduleUISync([.contentToolbar, .contentDashboard])
    case .persistedDataAvailability:
      scheduleUISync([.contentToolbar, .contentChrome])
    case .metrics:
      scheduleUISync([.sidebar])
    }
  }

  private func handleSelectionChange(_ change: SelectionSlice.Change) {
    switch change {
    case .selectedSessionID:
      var areas: Set<UISyncArea> = [.contentSession, .sidebar]
      if selection.selectedSessionID == nil {
        areas.insert(.inspector)
      }
      scheduleUISync(areas)
    case .selectedSession:
      scheduleUISync([.contentChrome, .contentSessionDetail, .inspector])
    case .timeline:
      scheduleUISync([.contentSessionDetail])
    case .inspectorSelection, .actionActorID:
      scheduleUISync([.inspector])
    case .selectionLoading, .extensionsLoading:
      scheduleUISync([.contentSession])
    case .sessionAction:
      scheduleUISync([.contentToolbar, .contentSession, .contentDashboard, .inspector])
    case .inFlightActionID:
      scheduleUISync([.inspector])
    }
  }

  private func handleSessionIndexChange(_ change: SessionIndexSlice.Change) {
    switch change {
    case .snapshot:
      scheduleUISync([.contentToolbar, .contentChrome, .contentSession, .inspector])
    case .summaryProjection(let sessionID):
      var areas: Set<UISyncArea> = [.contentToolbar]
      if shouldSyncSelectedSessionLoadingChrome(for: sessionID) {
        areas.insert(.contentSession)
      }
      scheduleUISync(areas)
    case .summaryMetadata(let sessionID):
      guard shouldSyncSelectedSessionLoadingChrome(for: sessionID) else {
        return
      }
      scheduleUISync([.contentSession])
    case .projection:
      break
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

  private func shouldSyncSelectedSessionLoadingChrome(for sessionID: String) -> Bool {
    guard selection.selectedSessionID == sessionID else {
      return false
    }
    return selection.matchedSelectedSession == nil
  }

  private func syncContentShellUI() {
    contentUI.shell.apply(
      ContentShellState(
        connectionState: connectionState,
        pendingConfirmation: pendingConfirmation,
        presentedSheet: presentedSheet
      )
    )
  }

  private func syncContentToolbarUI() {
    let toolbarMetrics = ToolbarMetricsState(
      projectCount: indexedProjectCount,
      worktreeCount: indexedWorktreeCount,
      sessionCount: indexedSessionCount,
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
    assign(canNavigateBack, to: \.canNavigateBack, on: contentUI.toolbar)
    assign(canNavigateForward, to: \.canNavigateForward, on: contentUI.toolbar)
    assign(isRefreshing, to: \.isRefreshing, on: contentUI.toolbar)
    assign(sleepPreventionEnabled, to: \.sleepPreventionEnabled, on: contentUI.toolbar)
    assign(connectionState, to: \.connectionState, on: contentUI.toolbar)
    assign(isBusy, to: \.isBusy, on: contentUI.toolbar)
  }

  private func syncContentChromeUI() {
    let selectedDetail = selection.matchedSelectedSession

    contentUI.chrome.apply(
      ContentChromeState(
        persistenceError: persistenceError,
        sessionDataAvailability: sessionDataAvailability,
        sessionStatus: selectedDetail?.session.status
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
    let selectedSessionSummary = sessionIndex.sessionSummary(for: selection.selectedSessionID)
    contentUI.sessionDetail.apply(
      ContentSessionDetailState(
        selectedSessionDetail: selection.matchedSelectedSession,
        timeline: selection.timeline
      ),
      selectedSessionSummary: selectedSessionSummary
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

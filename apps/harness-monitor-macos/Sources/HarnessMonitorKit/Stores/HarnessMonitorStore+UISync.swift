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
      ])
    case .daemonStatus:
      scheduleUISync([.contentToolbar, .contentDashboard, .sidebar])
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
      scheduleUISync([.contentSession, .sidebar])
    case .selectedSession:
      scheduleUISync([.contentChrome, .contentSessionDetail])
    case .selectedSessionDetail:
      scheduleUISync([.contentSessionDetail])
    case .timeline, .timelineWindow, .timelineLoading:
      scheduleUISync([.contentSessionDetail])
    case .actionActorID:
      break
    case .selectionLoading, .extensionsLoading:
      scheduleUISync([.contentSession])
    case .sessionAction:
      scheduleUISync([.contentToolbar, .contentSession, .contentDashboard])
    case .inFlightActionID:
      break
    }
  }

  private func handleSessionIndexChange(_ change: SessionIndexSlice.Change) {
    switch change {
    case .snapshot:
      scheduleUISync([.contentToolbar, .contentChrome, .contentSession, .sidebar])
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
    assign(canNavigateBack, to: \.canNavigateBack, on: contentUI.toolbar)
    assign(canNavigateForward, to: \.canNavigateForward, on: contentUI.toolbar)
    assign(isRefreshing, to: \.isRefreshing, on: contentUI.toolbar)
    assign(sleepPreventionEnabled, to: \.sleepPreventionEnabled, on: contentUI.toolbar)
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
        timeline: selection.timeline,
        timelineWindow: selection.timelineWindow,
        tuiStatusByAgent: tuiStatusByAgent(for: selection.matchedSelectedSession),
        isTimelineLoading: selection.isTimelineLoading,
        retainPresentedDetailWhenSelectionClears: selection
          .retainPresentedDetailWhenSelectionClears
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

  private func tuiStatusByAgent(for detail: SessionDetail?) -> [String: AgentTuiStatus] {
    guard let detail else {
      return [:]
    }

    var snapshotStatus: [String: AgentTuiStatus] = [:]
    snapshotStatus.reserveCapacity(selectedAgentTuis.count)
    for tui in selectedAgentTuis {
      if let existing = snapshotStatus[tui.agentId] {
        if tui.status.isActive && !existing.isActive {
          snapshotStatus[tui.agentId] = tui.status
        }
      } else {
        snapshotStatus[tui.agentId] = tui.status
      }
    }

    var result: [String: AgentTuiStatus] = [:]
    result.reserveCapacity(detail.agents.count)
    for agent in detail.agents {
      if let status = snapshotStatus[agent.agentId] {
        result[agent.agentId] = status
      } else if agent.capabilities.contains("agent-tui") {
        result[agent.agentId] = agent.status == .active ? .running : .exited
      }
    }
    return result
  }

  private func syncSidebarUI() {
    sidebarUI.apply(
      SidebarUIState(
        connectionMetrics: connectionMetrics,
        selectedSessionID: selection.selectedSessionID,
        isPersistenceAvailable: isPersistenceAvailable,
        bookmarkedSessionIds: userData.bookmarkedSessionIds,
        projectCount: indexedProjectCount,
        worktreeCount: indexedWorktreeCount,
        sessionCount: indexedSessionCount,
        openWorkCount: sessionIndex.totalOpenWorkCount,
        blockedCount: sessionIndex.totalBlockedCount
      )
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

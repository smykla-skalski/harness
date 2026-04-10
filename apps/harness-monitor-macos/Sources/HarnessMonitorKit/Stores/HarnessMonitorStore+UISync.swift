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
    let contentDashboard = contentUI.dashboard
    let toolbarMetrics = ToolbarMetricsState(
      projectCount: daemonStatus?.projectCount ?? sessionIndex.projects.count,
      worktreeCount: daemonStatus?.worktreeCount
        ?? sessionIndex.projects.reduce(0) { $0 + $1.worktrees.count },
      sessionCount: daemonStatus?.sessionCount ?? sessionIndex.sessions.count,
      openWorkCount: sessionIndex.totalOpenWorkCount,
      blockedCount: sessionIndex.totalBlockedCount
    )

    assign(selection.selectedSessionID, to: \.selectedSessionID, on: contentShell)
    assign(
      selectedDetail != nil || selectedSessionSummary != nil ? "Cockpit" : "Dashboard",
      to: \.windowTitle,
      on: contentShell
    )
    assign(connectionState, to: \.connectionState, on: contentShell)
    assign(isRefreshing, to: \.isRefreshing, on: contentShell)
    assign(isSelectionLoading, to: \.isSelectionLoading, on: contentShell)
    assign(isExtensionsLoading, to: \.isExtensionsLoading, on: contentShell)
    assign(lastAction, to: \.lastAction, on: contentShell)
    assign(pendingConfirmation, to: \.pendingConfirmation, on: contentShell)
    assign(presentedSheet, to: \.presentedSheet, on: contentShell)

    assign(persistenceError, to: \.persistenceError, on: contentChrome)
    assign(sessionDataAvailability, to: \.sessionDataAvailability, on: contentChrome)
    assign(
      selectedDetail?.session.status ?? selectedSessionSummary?.status,
      to: \.sessionStatus,
      on: contentChrome
    )
    assign(toolbarMetrics, to: \.toolbarMetrics, on: contentToolbar)
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

    assign(selectedDetail, to: \.selectedSessionDetail, on: contentSession)
    assign(selectedSessionSummary, to: \.selectedSessionSummary, on: contentSession)
    assign(selection.timeline, to: \.timeline, on: contentSession)
    assign(isSessionReadOnly, to: \.isSessionReadOnly, on: contentSession)
    assign(isSessionActionInFlight, to: \.isSessionActionInFlight, on: contentSession)
    assign(isSelectionLoading, to: \.isSelectionLoading, on: contentSession)
    assign(isExtensionsLoading, to: \.isExtensionsLoading, on: contentSession)
    assign(lastAction, to: \.lastAction, on: contentSession)

    assign(
      daemonStatus?.launchAgent.installed == true,
      to: \.isLaunchAgentInstalled,
      on: contentDashboard
    )
    assign(isBusy, to: \.isBusy, on: contentDashboard)
    assign(connectionState, to: \.connectionState, on: contentDashboard)
    assign(isRefreshing, to: \.isRefreshing, on: contentDashboard)
  }

  private func syncSidebarUI() {
    assign(connectionMetrics, to: \.connectionMetrics, on: sidebarUI)
    assign(selection.selectedSessionID, to: \.selectedSessionID, on: sidebarUI)
    assign(isPersistenceAvailable, to: \.isPersistenceAvailable, on: sidebarUI)
    assign(userData.bookmarkedSessionIds, to: \.bookmarkedSessionIds, on: sidebarUI)
  }

  private func syncInspectorUI() {
    assign(isPersistenceAvailable, to: \.isPersistenceAvailable, on: inspectorUI)
    assign(resolvedActionActor() ?? "", to: \.selectedActionActorID, on: inspectorUI)
    assign(isSessionReadOnly, to: \.isSessionReadOnly, on: inspectorUI)
    assign(isSessionActionInFlight, to: \.isSessionActionInFlight, on: inspectorUI)
    assign(lastAction, to: \.lastAction, on: inspectorUI)
    assign(lastError, to: \.lastError, on: inspectorUI)

    let resolvedPrimaryContent = InspectorPrimaryContentState(
      selectedSession: selection.matchedSelectedSession,
      selectedSessionSummary: contentUI.session.selectedSessionSummary,
      inspectorSelection: selection.inspectorSelection,
      isPersistenceAvailable: isPersistenceAvailable
    )
    assign(resolvedPrimaryContent, to: \.primaryContent, on: inspectorUI)

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
    assign(resolvedActionContext, to: \.actionContext, on: inspectorUI)
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

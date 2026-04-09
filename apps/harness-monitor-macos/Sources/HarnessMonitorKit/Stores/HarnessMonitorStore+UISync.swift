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
    let toolbarMetrics = ToolbarMetricsState(
      projectCount: daemonStatus?.projectCount ?? sessionIndex.projects.count,
      worktreeCount: daemonStatus?.worktreeCount
        ?? sessionIndex.projects.reduce(0) { $0 + $1.worktrees.count },
      sessionCount: daemonStatus?.sessionCount ?? sessionIndex.sessions.count,
      openWorkCount: sessionIndex.totalOpenWorkCount,
      blockedCount: sessionIndex.totalBlockedCount
    )

    assign(selection.selectedSessionID, to: \.selectedSessionID, on: contentUI)
    assign(selectedSessionSummary, to: \.selectedSessionSummary, on: contentUI)
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
      selectedSessionSummary: contentUI.selectedSessionSummary,
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


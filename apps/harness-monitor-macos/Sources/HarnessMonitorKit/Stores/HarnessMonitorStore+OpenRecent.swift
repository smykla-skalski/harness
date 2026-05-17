import Foundation

extension HarnessMonitorStore {
  public func prepareOpenRecentSessions() async {
    await refreshBookmarkedSessionIds()
    await restoreOpenRecentSessionCatalog()
  }

  public func refreshOpenRecentSessions() async {
    guard !isRefreshing, !isBootstrapping else {
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    if let client {
      await refresh(
        using: client,
        preserveSelection: false,
        allowPreviewReadySelection: false
      )
    } else {
      await connectOpenRecentSessionCatalog()
    }

    guard connectionState == .online else {
      return
    }
    manualRefreshSuccessToken &+= 1
  }

  private func connectOpenRecentSessionCatalog() async {
    connectionState = .connecting
    isBootstrapping = true
    defer {
      isBootstrapping = false
      replayQueuedReconnectAfterBootstrapIfNeeded()
    }

    await refreshBookmarkedSessionIds()
    await refreshPersistedSessionMetadata()

    switch daemonOwnership {
    case .external:
      await bootstrapExternalDaemon()
    case .managed:
      await bootstrapManagedDaemon()
    }
  }

  private func restoreOpenRecentSessionCatalog() async {
    await refreshPersistedSessionMetadata()
    guard sessionIndex.catalog.sessions.isEmpty,
      let cached = await loadCachedSessionList()
    else {
      return
    }

    let filteredCached = sessionIndexSnapshotApplyingRemovedSessionSuppression(
      projects: cached.projects,
      sessions: cached.sessions
    )
    withUISyncBatch {
      sessionIndex.replaceSnapshot(
        projects: filteredCached.projects,
        sessions: filteredCached.sessions
      )
      isShowingCachedCatalog = persistedSessionCount > 0 || !sessions.isEmpty
    }
  }
}

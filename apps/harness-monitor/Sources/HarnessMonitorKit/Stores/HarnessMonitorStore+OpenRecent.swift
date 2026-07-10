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

    if usesRemoteDaemon {
      await bootstrapRemoteDaemon()
      return
    }
    ensureLocalManifestURL()
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

    let generation = beginSessionIndexSnapshotApply()
    guard
      let filteredCached = await preparedSessionIndexSnapshot(
        projects: cached.projects,
        sessions: cached.sessions,
        generation: generation
      )
    else {
      return
    }
    replaceCachedSessionIndexSnapshot(filteredCached, updateCachedCatalogFlag: true)
  }
}

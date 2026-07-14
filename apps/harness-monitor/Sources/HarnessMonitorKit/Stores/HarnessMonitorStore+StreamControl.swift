import Foundation

extension HarnessMonitorStore {
  func stopGlobalStream() {
    globalStreamTask?.cancel()
    globalStreamTask = nil
    cacheWriteSync.taskBoardRefreshGeneration &+= 1
    cacheWriteSync.taskBoardRefreshTask?.cancel()
    cacheWriteSync.taskBoardRefreshTask = nil
    cacheWriteSync.taskBoardRefreshCompletedGeneration =
      cacheWriteSync.taskBoardRefreshRequestGeneration
    cacheWriteSync.taskBoardRefreshDeferralDepth = 0
    cacheWriteSync.pendingTaskBoardItemsRefresh = false
    cacheWriteSync.pendingTaskBoardOrchestratorRefresh = false
    cacheWriteSync.pendingTaskBoardFallbackStatus = nil
  }

  func stopSessionStream(resetSubscriptions: Bool = true) {
    sessionStreamTask?.cancel()
    sessionStreamTask = nil
    if resetSubscriptions {
      subscribedSessionIDs.removeAll()
    }
  }

  @discardableResult
  func disconnectActiveConnection(
    resetSubscriptions: Bool = true
  ) -> (any HarnessMonitorClientProtocol)? {
    stopAllStreams(resetSubscriptions: resetSubscriptions)
    let disconnectedClient = client
    client = nil
    taskBoardDatabaseInstanceID = nil
    lastTaskBoardCredentialSync = nil
    return disconnectedClient
  }

  func stopAllStreams(resetSubscriptions: Bool = true) {
    stopGlobalStream()
    stopSessionStream(resetSubscriptions: resetSubscriptions)
    stopConnectionProbe()
    cancelSelectedSessionRefreshFallback()
    cancelSessionPushFallback()
    cancelSessionLoad()
    cancelInitialTaskBoardConfirmationRefresh()
    cancelPendingCacheWrite()
    sessionSnapshotHydrationTask?.cancel()
    sessionSnapshotHydrationTask = nil
  }
}

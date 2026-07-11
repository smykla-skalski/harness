import Foundation

extension HarnessMonitorStore {
  func stopGlobalStream() {
    globalStreamTask?.cancel()
    globalStreamTask = nil
    cacheWriteSync.githubDataRefreshGeneration &+= 1
    cacheWriteSync.githubDataTaskBoardRefreshTask?.cancel()
    cacheWriteSync.githubDataTaskBoardRefreshTask = nil
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

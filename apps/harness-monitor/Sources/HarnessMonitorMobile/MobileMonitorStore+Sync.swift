import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorMirrorStore

private struct MobileRefreshState {
  var aggregateSnapshot: MobileMirrorSnapshot
  var latestGeneratedAt: Date?
  var selectedStationRefreshed = false
  var failureReason: String?
  var failureStatus: MobileMonitorSyncStatus?
}

private struct MobileRefreshRequest {
  let stationID: String
  let preferredStationID: String
  let generation: UInt64
  let now: Date
}

extension MobileMonitorStore {
  func refresh() async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    guard !applyDemoRefreshIfNeeded() else { return }
    let stationIDs = stationIDsForRefresh()
    guard let preferredStationID = preferredLiveStationID() ?? stationIDs.first else {
      applyCachedSnapshotIfAvailable()
      syncStatus = .unpaired
      return
    }

    syncStatus = .syncing
    let now = Date()
    guard
      let refreshState = await performRefresh(
        stationIDs: stationIDs,
        preferredStationID: preferredStationID,
        generation: generation,
        now: now
      )
    else {
      return
    }

    await applyRefreshState(refreshState, preferredStationID: preferredStationID)
  }

  private func applyDemoRefreshIfNeeded() -> Bool {
    guard demoModeEnabled else {
      return false
    }
    refreshDemoData()
    syncStatus = .demo
    return true
  }

  private func performRefresh(
    stationIDs: [String],
    preferredStationID: String,
    generation: UInt64,
    now: Date
  ) async -> MobileRefreshState? {
    var state = MobileRefreshState(aggregateSnapshot: snapshot)

    for stationID in stationIDs {
      guard let syncClient = syncClient(for: stationID) else {
        continue
      }
      let request = MobileRefreshRequest(
        stationID: stationID,
        preferredStationID: preferredStationID,
        generation: generation,
        now: now
      )
      guard
        let nextState = await refreshState(
          from: state,
          syncClient: syncClient,
          request: request
        )
      else {
        return nil
      }
      state = nextState
    }

    guard isCurrentRefresh(generation) else {
      return nil
    }
    return state
  }

  private func refreshState(
    from refreshState: MobileRefreshState,
    syncClient: any MobileMonitorSyncClient,
    request: MobileRefreshRequest
  ) async -> MobileRefreshState? {
    var nextState = refreshState

    do {
      guard
        let fetched = try await fetchLatestSnapshot(
          using: syncClient,
          stationID: request.stationID,
          now: request.now
        )
      else {
        guard isCurrentRefresh(request.generation) else {
          return nil
        }
        nextState.failureReason = mobileMonitorNoEncryptedMirrorMessage
        return nextState
      }
      guard isCurrentRefresh(request.generation) else {
        return nil
      }
      nextState.aggregateSnapshot = nextState.aggregateSnapshot.mergingStationSnapshot(
        fetched,
        stationID: request.stationID,
        defaultStationID: defaultStationID
      )
      nextState.latestGeneratedAt = max(
        nextState.latestGeneratedAt ?? fetched.generatedAt,
        fetched.generatedAt
      )
      nextState.selectedStationRefreshed =
        request.stationID == request.preferredStationID || nextState.selectedStationRefreshed
      return nextState
    } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
      guard isCurrentRefresh(request.generation) else {
        return nil
      }
      nextState.failureReason =
        "Last encrypted mirror expired \(expiresAt.formatted(.relative(presentation: .numeric)))."
      nextState.failureStatus = .stale(nextState.failureReason ?? "Last encrypted mirror expired.")
      return nextState
    } catch {
      guard isCurrentRefresh(request.generation) else {
        return nil
      }
      nextState.failureStatus = mobileMonitorSyncStatus(for: error)
      nextState.failureReason = mobileMirrorReadableErrorDescription(error)
      return nextState
    }
  }

  private func applyRefreshState(
    _ refreshState: MobileRefreshState,
    preferredStationID: String
  ) async {
    guard let latestGeneratedAt = refreshState.latestGeneratedAt else {
      applyCachedSnapshotIfAvailable()
      syncStatus =
        refreshState.failureStatus
        ?? .stale(refreshState.failureReason ?? mobileMonitorNoEncryptedMirrorMessage)
      return
    }

    let previous = applyAggregateSnapshot(
      refreshState.aggregateSnapshot,
      preferredStationID: preferredStationID
    )
    syncStatus =
      refreshState.selectedStationRefreshed
      ? .live(latestGeneratedAt)
      : .stale(refreshState.failureReason ?? "Selected station did not refresh.")
    await scheduleNotifications(previous: previous, next: refreshState.aggregateSnapshot)
  }

  func fetchLatestSnapshot(
    using syncClient: any MobileMonitorSyncClient,
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    try await MobileAsyncTimeout.run(
      timeout: syncFetchTimeout,
      timeoutError: { MobileMirrorRefreshTimeout() },
      operation: {
        try await syncClient.fetchLatestSnapshot(stationID: stationID, now: now)
      }
    )
  }

  func refreshDemoData() {
    _ = applyAggregateSnapshot(
      MobileDemoFixtures.snapshot(),
      preferredStationID: selectedStationID
    )
  }

  func loadStoredPairings() async {
    guard !demoModeEnabled else {
      return
    }
    do {
      try await rebuildSyncClients()
      syncStatus =
        pairedCredentials.isEmpty
        ? .unpaired
        : .paired(pairedCredentials.first?.stationName ?? "Mac")
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
    }
  }

  func handleOpenURL(_ url: URL, deviceName: String) async {
    guard url.scheme == MobilePairingInvitationCodec.urlScheme,
      url.host == MobilePairingInvitationCodec.urlHost
    else {
      return
    }
    await pair(invitationURL: url, deviceName: deviceName)
  }

  func pair(invitationURL: URL, deviceName: String) async {
    guard let pairer else {
      syncStatus = .stale("Pairing service is unavailable.")
      return
    }
    do {
      let invitation = try MobilePairingInvitationCodec.decode(invitationURL, now: .now)
      let wasDemoModeEnabled = demoModeEnabled
      demoModeEnabled = false
      if wasDemoModeEnabled {
        snapshot = .empty()
        selectedStationID = ""
      }
      syncStatus = .pairing(invitation.stationName)
      let credential = try await pairer.pair(
        invitationURL: invitationURL,
        deviceName: deviceName,
        now: .now
      )
      try await rebuildSyncClients(preferredStationID: credential.stationID)
      syncStatus = .paired(credential.stationName)
      await refreshAfterPairingBootstrap()
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
    }
  }

  func unpair(stationID: String) async {
    guard let identityStore, let credentialStore else {
      syncStatus = .stale("Pairing storage is unavailable.")
      return
    }
    do {
      let removedCredential = try await credentialStore.load(stationID: stationID)
      try await credentialStore.delete(stationID: stationID)
      let remainingCredentials = try await credentialStore.loadAll()
      if let removedCredential,
        !remainingCredentials.contains(where: {
          $0.deviceIdentityID == removedCredential.deviceIdentityID
        })
      {
        try await identityStore.delete(id: removedCredential.deviceIdentityID)
      }
      syncClientsByStationID.removeValue(forKey: stationID)
      snapshot.commands.removeAll { $0.stationID == stationID }
      snapshot.attention.removeAll { $0.stationID == stationID }
      snapshot.sessions.removeAll { $0.stationID == stationID }
      snapshot.reviews.removeAll { $0.stationID == stationID }
      snapshot.taskBoardItems.removeAll { $0.stationID == stationID }
      snapshot.stations.removeAll { $0.id == stationID }
      selectedStationID =
        snapshot.stations.first(where: \.defaultStation)?.id
        ?? snapshot.stations.first?.id
        ?? ""
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      try await rebuildSyncClients(preferredStationID: selectedStationID)
      syncStatus =
        pairedCredentials.isEmpty
        ? .unpaired
        : .paired(pairedCredentials.first?.stationName ?? "Mac")
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
    }
  }
}

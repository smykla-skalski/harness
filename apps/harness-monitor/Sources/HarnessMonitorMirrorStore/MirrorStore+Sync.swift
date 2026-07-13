import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto

private struct MobileRefreshState {
  var aggregateSnapshot: MobileMirrorSnapshot
  var latestGeneratedAt: Date?
  var selectedStationRefreshed = false
  var failureReason: String?
  var failureStatus: MirrorSyncStatus?
  var sawMissingMirror = false
}

private struct MobileRefreshRequest {
  let stationID: String
  let preferredStationID: String
  let now: Date
}

extension MirrorStore {
  public func refresh() async {
    // Single-flight: serialize refreshes so a burst of callers can never leave
    // syncStatus pinned at .syncing. A refresh requested while one is already
    // running just records that another pass is wanted; the running refresh
    // re-runs once it settles, so the last requested refresh always reaches a
    // terminal status even under a continuous superseder.
    guard !isRefreshing else {
      pendingRefreshRequested = true
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }
    repeat {
      pendingRefreshRequested = false
      await performRefreshPass()
    } while pendingRefreshRequested
  }

  private func performRefreshPass() async {
    guard !applyDemoRefreshIfNeeded() else { return }
    let stationIDs = stationIDsForRefresh()
    guard let preferredStationID = preferredLiveStationID() ?? stationIDs.first else {
      applyCachedSnapshotIfAvailable()
      syncStatus = .unpaired
      return
    }

    syncStatus = .syncing
    let now = Date()
    let refreshState = await performRefresh(
      stationIDs: stationIDs,
      preferredStationID: preferredStationID,
      now: now
    )
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
    now: Date
  ) async -> MobileRefreshState {
    var state = MobileRefreshState(aggregateSnapshot: snapshot)

    for stationID in stationIDs {
      guard let syncClient = syncClient(for: stationID) else {
        continue
      }
      let request = MobileRefreshRequest(
        stationID: stationID,
        preferredStationID: preferredStationID,
        now: now
      )
      state = await refreshState(
        from: state,
        syncClient: syncClient,
        request: request
      )
    }

    return state
  }

  private func refreshState(
    from refreshState: MobileRefreshState,
    syncClient: any MobileMonitorSyncClient,
    request: MobileRefreshRequest
  ) async -> MobileRefreshState {
    var nextState = refreshState

    do {
      guard
        let fetched = try await fetchLatestSnapshot(
          using: syncClient,
          stationID: request.stationID,
          now: request.now
        )
      else {
        nextState.failureReason = mobileMonitorNoEncryptedMirrorMessage
        nextState.sawMissingMirror = true
        return nextState
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
      nextState.failureReason =
        "Last encrypted mirror expired \(expiresAt.formatted(.relative(presentation: .numeric)))."
      nextState.failureStatus = .stale(nextState.failureReason ?? "Last encrypted mirror expired.")
      return nextState
    } catch {
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
      if refreshState.sawMissingMirror {
        requestFreshPairingMaterialIfThrottleAllows()
      }
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

  public func loadStoredPairings() async {
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

  public func handleOpenURL(_ url: URL, deviceName: String) async {
    guard MobilePairingLink.supports(url) else {
      return
    }
    _ = await pair(invitationURL: url, deviceName: deviceName)
  }

  @discardableResult
  func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date = .now
  ) async -> MobilePairedStationCredential? {
    pairingFailureDescription = nil
    guard let pairer else {
      recordPairingFailure("Pairing service is unavailable.")
      return nil
    }
    do {
      let pairingLink = try MobilePairingLink.decode(invitationURL, now: now)
      let cloudFallbackStationID = cloudFallbackStationID(for: pairingLink)
      let wasDemoModeEnabled = demoModeEnabled
      demoModeEnabled = false
      if wasDemoModeEnabled {
        snapshot = .empty()
        selectedStationID = ""
      }
      syncStatus = .pairing(pairingLink.stationName)
      let credential = try await pairer.pair(
        invitationURL: invitationURL,
        deviceName: deviceName,
        cloudFallbackStationID: cloudFallbackStationID,
        now: now
      )
      try await rebuildSyncClients(preferredStationID: credential.stationID)
      syncStatus = .paired(credential.stationName)
      await refreshAfterPairingBootstrap()
      return credential
    } catch {
      recordPairingFailure(mobileMirrorReadableErrorDescription(error))
      return nil
    }
  }

  func recordPairingFailure(_ description: String) {
    let status = MirrorSyncStatus.pairingFailed(description)
    pairingFailureDescription = description
    syncStatus = status
  }

  private func cloudFallbackStationID(for pairingLink: MobilePairingLink) -> String? {
    guard case .remote(let invitation) = pairingLink else {
      return nil
    }
    let compatibleCredentials = pairedCredentials.filter { credential in
      credential.hasCloudMirrorAccess
        && (credential.remoteDaemonAccess == nil
          || credential.remoteDaemonAccess?.endpoint == invitation.endpoint)
    }
    if let selected = compatibleCredentials.first(where: {
      $0.stationID == selectedStationID
    }) {
      return selected.stationID
    }
    guard compatibleCredentials.count == 1 else {
      return nil
    }
    return compatibleCredentials[0].stationID
  }

  public func unpair(stationID: String) async {
    pairingFailureDescription = nil
    guard let identityStore, let credentialStore else {
      syncStatus = .stale("Pairing storage is unavailable.")
      return
    }
    do {
      let removedCredential = try await credentialStore.load(stationID: stationID)
      try await credentialStore.delete(stationID: stationID)
      let remainingCredentials = try await credentialStore.loadAll()
      let retainedIdentityIDs = Set(
        remainingCredentials.flatMap(\.referencedDeviceIdentityIDs)
      )
      if let removedCredential {
        for identityID in removedCredential.referencedDeviceIdentityIDs
        where !retainedIdentityIDs.contains(identityID) {
          try await identityStore.delete(id: identityID)
        }
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

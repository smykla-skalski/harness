import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

extension MobileMonitorStore {
  func refresh() async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    if demoModeEnabled {
      refreshDemoData()
      syncStatus = .demo
      return
    }
    let stationIDs = stationIDsForRefresh()
    guard !stationIDs.isEmpty else {
      applyCachedSnapshotIfAvailable()
      syncStatus = .unpaired
      return
    }

    syncStatus = .syncing
    let now = Date()
    let preferredStationID = preferredLiveStationID() ?? stationIDs[0]
    var aggregateSnapshot = snapshot
    var latestGeneratedAt: Date?
    var selectedStationRefreshed = false
    var failureReason: String?
    var failureStatus: MobileMonitorSyncStatus?

    for stationID in stationIDs {
      guard let syncClient = syncClient(for: stationID) else {
        continue
      }
      do {
        guard
          let fetched = try await fetchLatestSnapshot(
            using: syncClient,
            stationID: stationID,
            now: now
          )
        else {
          guard isCurrentRefresh(generation) else {
            return
          }
          failureReason = "No encrypted mirror snapshot found."
          continue
        }
        guard isCurrentRefresh(generation) else {
          return
        }
        aggregateSnapshot = aggregateSnapshot.mergingStationSnapshot(
          fetched,
          stationID: stationID,
          defaultStationID: defaultStationID
        )
        latestGeneratedAt = max(latestGeneratedAt ?? fetched.generatedAt, fetched.generatedAt)
        selectedStationRefreshed = stationID == preferredStationID || selectedStationRefreshed
      } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
        guard isCurrentRefresh(generation) else {
          return
        }
        failureReason =
          "Last encrypted mirror expired \(expiresAt.formatted(.relative(presentation: .numeric)))."
        failureStatus = .stale(failureReason ?? "Last encrypted mirror expired.")
      } catch {
        guard isCurrentRefresh(generation) else {
          return
        }
        failureStatus = mobileMonitorSyncStatus(for: error)
        failureReason = mobileMonitorReadableErrorDescription(error)
      }
    }

    guard isCurrentRefresh(generation) else {
      return
    }
    guard let latestGeneratedAt else {
      applyCachedSnapshotIfAvailable()
      syncStatus = failureStatus ?? .stale(failureReason ?? "No encrypted mirror snapshot found.")
      return
    }

    let previous = applyAggregateSnapshot(
      aggregateSnapshot,
      preferredStationID: preferredStationID
    )
    syncStatus =
      selectedStationRefreshed
      ? .live(latestGeneratedAt)
      : .stale(failureReason ?? "Selected station did not refresh.")
    await scheduleNotifications(previous: previous, next: aggregateSnapshot)
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

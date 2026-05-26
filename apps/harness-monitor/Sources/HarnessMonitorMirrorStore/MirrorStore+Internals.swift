import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import WidgetKit

extension MirrorStore {
  func applyAggregateSnapshot(
    _ nextSnapshot: MobileMirrorSnapshot,
    preferredStationID: String?
  ) -> MobileMirrorSnapshot {
    let previousSnapshot = snapshot
    snapshot = nextSnapshot
    persistSharedSnapshot(nextSnapshot)
    publishWatchPairingTransfer(snapshot: nextSnapshot)
    if let preferredStationID, snapshot.stations.contains(where: { $0.id == preferredStationID }) {
      selectedStationID = preferredStationID
    } else {
      selectedStationID =
        snapshot.stations.first(where: \.defaultStation)?.id
        ?? snapshot.stations.first?.id
        ?? ""
    }
    reconcileLiveActivity(nextSnapshot)
    return previousSnapshot
  }

  func scheduleNotifications(
    previous: MobileMirrorSnapshot?,
    next: MobileMirrorSnapshot
  ) async {
    guard let notificationScheduler else {
      return
    }
    let plannedRequests = MobileNotificationPlanner.requests(
      previous: previous,
      next: next,
      settings: notificationSettings
    )
    let newRequests = notificationDeliveryHistory.unrecordedRequests(plannedRequests)
    let scheduledRequestIDs = await notificationScheduler.schedule(newRequests)
    notificationDeliveryHistory.recordDeliveredRequestIDs(scheduledRequestIDs)
  }

  func persistSharedSnapshot(_ nextSnapshot: MobileMirrorSnapshot) {
    do {
      try sharedSnapshotStore?.save(nextSnapshot)
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      syncStatus = .stale("Could not update widgets: \(String(describing: error))")
    }
  }

  func reconcileLiveActivity(_ nextSnapshot: MobileMirrorSnapshot) {
    let preferredStationID = selectedStationID
    Task { [liveActivityCoordinator] in
      await liveActivityCoordinator?.reconcile(
        snapshot: nextSnapshot,
        preferredStationID: preferredStationID
      )
    }
  }

  func rebuildSyncClients(preferredStationID: String? = nil) async throws {
    guard let identityStore, let credentialStore else {
      return
    }
    let credentials = try await credentialStore.loadAll()
    var nextClients: [String: any MobileMonitorSyncClient] = [:]
    var validCredentials: [MobilePairedStationCredential] = []
    var identitiesByID: [String: MobileDeviceIdentity] = [:]
    for credential in credentials {
      guard let identity = try await identityStore.load(id: credential.deviceIdentityID) else {
        continue
      }
      validCredentials.append(credential)
      identitiesByID[identity.id] = identity
      nextClients[credential.stationID] = syncClientFactory.makeSyncClient(
        credential: credential,
        identity: identity
      )
    }
    pairedCredentials = validCredentials
    pairedIdentitiesByID = identitiesByID
    syncClientsByStationID = nextClients
    defaultStationID =
      preferredStationID
      ?? validCredentials.first(where: \.defaultStation)?.stationID
      ?? validCredentials.first?.stationID
    if let defaultStationID, !defaultStationID.isEmpty {
      selectedStationID = defaultStationID
    }
    applyPairedStationPlaceholders(validCredentials)
    await watchPairingSyncer?.publish(
      identities: identitiesByID.values.sorted { $0.id < $1.id },
      credentials: validCredentials,
      snapshot: snapshot,
      exportedAt: .now
    )
  }

  func publishWatchPairingTransfer(snapshot: MobileMirrorSnapshot) {
    guard !pairedCredentials.isEmpty else {
      return
    }
    let identities = pairedIdentitiesByID.values.sorted { $0.id < $1.id }
    let credentials = pairedCredentials
    Task { [watchPairingSyncer] in
      await watchPairingSyncer?.publish(
        identities: identities,
        credentials: credentials,
        snapshot: snapshot,
        exportedAt: .now
      )
    }
  }

  func applyCachedSnapshotIfAvailable() {
    guard let cachedSnapshot = try? sharedSnapshotStore?.loadLatestSnapshot() else {
      return
    }
    snapshot = cachedSnapshot
    if selectedStationID.isEmpty || snapshot.station(id: selectedStationID) == nil {
      selectedStationID =
        defaultStationID
        ?? snapshot.stations.first(where: \.defaultStation)?.id
        ?? snapshot.stations.first?.id
        ?? ""
    }
    reconcileLiveActivity(cachedSnapshot)
  }

  func refreshAfterPairingBootstrap() async {
    let retryDelays: [Duration] = [
      .zero,
      .seconds(1),
      .seconds(3),
      .seconds(6),
      .seconds(10),
      .seconds(15),
    ]
    for (index, delay) in retryDelays.enumerated() {
      if index > 0 {
        try? await Task.sleep(for: delay)
      }
      await refresh()
      if case .live = syncStatus {
        return
      }
    }
  }

  public func runForegroundRefreshLoop() async {
    var backoff = MobileForegroundRefreshBackoff()
    while !Task.isCancelled {
      try? await Task.sleep(for: backoff.currentInterval)
      guard !Task.isCancelled, shouldRunForegroundRefresh else {
        continue
      }
      await refresh()
      if syncStatus.indicatesSyncFailure {
        backoff.recordFailure()
      } else {
        backoff.recordSuccess()
      }
    }
  }

  private var shouldRunForegroundRefresh: Bool {
    !demoModeEnabled && !stationIDsForRefresh().isEmpty
  }

  func applyPairedStationPlaceholders(
    _ credentials: [MobilePairedStationCredential],
    now: Date = .now
  ) {
    let changed = snapshot.ensurePairedStationPlaceholders(
      for: credentials,
      defaultStationID: defaultStationID,
      now: now
    )
    guard changed else {
      return
    }
    persistSharedSnapshot(snapshot)
    reconcileLiveActivity(snapshot)
  }

  func privacyStationIDs() -> [String] {
    var stationIDs: [String] = []
    appendUniqueStationIDs(pairedCredentials.map(\.stationID), to: &stationIDs)
    appendUniqueStationIDs(syncClientsByStationID.keys.sorted(), to: &stationIDs)
    appendUniqueStationIDs(snapshot.stations.map(\.id), to: &stationIDs)
    appendUniqueStationIDs([preferredLiveStationID()].compactMap(\.self), to: &stationIDs)
    return stationIDs
  }

  func appendUniqueStationIDs(_ incoming: [String], to stationIDs: inout [String]) {
    for stationID in incoming {
      let trimmed = stationID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !stationIDs.contains(trimmed) else {
        continue
      }
      stationIDs.append(trimmed)
    }
  }

  func preferredLiveStationID() -> String? {
    if !selectedStationID.isEmpty {
      return selectedStationID
    }
    return defaultStationID
  }

  func stationIDsForRefresh() -> [String] {
    let stationIDs = syncClientsByStationID.keys.sorted()
    guard !stationIDs.isEmpty else {
      guard let stationID = preferredLiveStationID() else {
        return injectedSyncClient == nil ? [] : [""]
      }
      return [stationID]
    }
    guard let preferredStationID = preferredLiveStationID(),
      stationIDs.contains(preferredStationID)
    else {
      return stationIDs
    }
    return [preferredStationID] + stationIDs.filter { $0 != preferredStationID }
  }

  func syncClient(for stationID: String) -> (any MobileMonitorSyncClient)? {
    if let injectedSyncClient {
      return injectedSyncClient
    }
    if let client = syncClientsByStationID[stationID] {
      return client
    }
    if stationID.isEmpty, let defaultStationID {
      return syncClientsByStationID[defaultStationID]
    }
    return nil
  }
}

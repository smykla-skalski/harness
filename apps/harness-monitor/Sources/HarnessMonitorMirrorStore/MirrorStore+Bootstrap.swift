import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

extension MirrorStore {
  /// Full bootstrap used by the watch: rebuild the sync clients, scope the
  /// cached snapshot to the paired stations, then refresh. The iOS app drives
  /// its own loadStoredPairings/refresh composition and does not call this.
  public func load() async {
    do {
      _ = try await activateStoredWatchPairingIfNeeded()
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
      return
    }
    guard !demoModeEnabled else {
      await refresh()
      return
    }
    do {
      try await rebuildSyncClients()
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
      return
    }
    guard !pairedCredentials.isEmpty else {
      applyCachedSnapshotIfAvailable()
      syncStatus = snapshot.stations.isEmpty ? .unpaired : .stale("Waiting for iPhone pairing.")
      return
    }
    scopeToPairedStations()
    await refresh()
  }

  func loadStoredWatchPairingIfAvailable() async {
    do {
      guard try await activateStoredWatchPairingIfNeeded() else { return }
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
      return
    }
    await load()
  }

  private func activateStoredWatchPairingIfNeeded() async throws -> Bool {
    guard profile == .watch, demoModeEnabled, let identityStore, let credentialStore else {
      return false
    }
    let credentials = try await credentialStore.loadAll()
    var hasUsableCredential = false
    for credential in credentials
    where try await identityStore.load(id: credential.deviceIdentityID) != nil {
      hasUsableCredential = true
      break
    }
    guard hasUsableCredential else { return false }
    leaveDemoModeForStoredWatchPairing()
    return true
  }

  private func leaveDemoModeForStoredWatchPairing() {
    demoModeEnabled = false
    snapshot = .empty()
    selectedStationID = ""
    syncStatus = .syncing
    persistSharedSnapshot(snapshot)
    reconcileLiveActivity(snapshot)
  }

  /// Resets transient pairing state and reloads after the iPhone pushes new
  /// pairing material to the watch.
  public func loadTransferredPairings() async {
    demoModeEnabled = false
    defaultStationID = nil
    syncClientsByStationID = [:]
    syncStatus = .syncing
    await load()
  }

  /// Drops cached data for stations the watch is no longer paired to, so a
  /// removed station stops lingering in the snapshot.
  func scopeToPairedStations() {
    let stationIDs = pairedCredentials.map(\.stationID)
    let scoped = snapshot.keepingStationData(
      for: stationIDs,
      defaultStationID: defaultStationID
    )
    guard scoped != snapshot else {
      return
    }
    snapshot = scoped
    persistSharedSnapshot(snapshot)
  }
}

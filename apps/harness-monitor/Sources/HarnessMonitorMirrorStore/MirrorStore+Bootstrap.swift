import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

extension MirrorStore {
  /// Full bootstrap used by the watch: rebuild the sync clients, scope the
  /// cached snapshot to the paired stations, then refresh. The iOS app drives
  /// its own loadStoredPairings/refresh composition and does not call this.
  public func load() async {
    await activateStoredWatchPairingIfNeeded()
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

  private func activateStoredWatchPairingIfNeeded() async {
    guard profile == .watch, demoModeEnabled, let credentialStore,
      let credentials = try? await credentialStore.loadAll(),
      !credentials.isEmpty
    else {
      return
    }
    demoModeEnabled = false
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

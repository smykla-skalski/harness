import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import LocalAuthentication
import Observation
import WidgetKit

enum WatchMonitorStatus: Equatable {
  case loading
  case demo
  case live(Date)
  case unpaired
  case stale(String)
  case commandQueued(Date)
  case commandCancelled(Date)
  case commandFailed(String)

  var title: String {
    switch self {
    case .loading: "Syncing"
    case .demo: "Demo station"
    case .live: "Live"
    case .unpaired: "No paired Mac"
    case .stale: "Stale"
    case .commandQueued: "Command queued"
    case .commandCancelled: "Command cancelled"
    case .commandFailed: "Command failed"
    }
  }

  var subtitle: String {
    switch self {
    case .loading:
      "Fetching mirror"
    case .demo:
      "App Review demo"
    case .live(let date):
      "Updated \(date.formatted(.relative(presentation: .numeric)))"
    case .unpaired:
      "Open iPhone pairing"
    case .stale(let reason), .commandFailed(let reason):
      reason
    case .commandQueued(let date):
      "Signed \(date.formatted(.dateTime.hour().minute()))"
    case .commandCancelled(let date):
      "Cancelled \(date.formatted(.dateTime.hour().minute()))"
    }
  }

  var systemImage: String {
    switch self {
    case .loading: "arrow.triangle.2.circlepath"
    case .demo: "testtube.2"
    case .live: "checkmark.icloud"
    case .unpaired: "link.badge.plus"
    case .stale: "exclamationmark.icloud"
    case .commandQueued: "checkmark.seal"
    case .commandCancelled: "xmark.seal"
    case .commandFailed: "xmark.octagon"
    }
  }
}

@MainActor
@Observable
final class WatchMonitorStore {
  var snapshot: MobileMirrorSnapshot
  var status: WatchMonitorStatus
  var demoModeEnabled: Bool
  var selectedStationID: String

  private let identityStore: any MobileDeviceIdentityStore
  private let credentialStore: any MobilePairedStationCredentialStore
  let sharedSnapshotStore: MobileSharedSnapshotStore?
  let syncFetchTimeout: Duration
  var syncClientsByStationID: [String: MobileCloudMirrorSyncClient] = [:]
  var defaultStationID: String?
  var requestFreshPairingMaterial: (@Sendable () -> Void)?
  private var refreshGeneration: UInt64 = 0
  private var pairingRefreshThrottle = MobilePairingRefreshThrottle()

  init(
    snapshot: MobileMirrorSnapshot? = nil,
    demoModeEnabled: Bool = false,
    identityStore: any MobileDeviceIdentityStore = KeychainMobileDeviceIdentityStore(),
    credentialStore: any MobilePairedStationCredentialStore =
      KeychainMobilePairedStationCredentialStore(),
    sharedSnapshotStore: MobileSharedSnapshotStore? = MobileSharedSnapshotStore(),
    syncFetchTimeout: Duration = .seconds(20)
  ) {
    self.demoModeEnabled = demoModeEnabled
    let cachedSnapshot = try? sharedSnapshotStore?.loadLatestSnapshot()
    let initialSnapshot =
      snapshot ?? (demoModeEnabled ? MobileDemoFixtures.snapshot() : cachedSnapshot ?? .empty())
    self.snapshot = initialSnapshot
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.sharedSnapshotStore = sharedSnapshotStore
    self.syncFetchTimeout = syncFetchTimeout
    self.status =
      if demoModeEnabled {
        .demo
      } else if let cachedSnapshot {
        .stale(
          "Showing last known mirror from "
            + "\(cachedSnapshot.generatedAt.formatted(.relative(presentation: .numeric)))."
        )
      } else {
        .loading
      }
    self.selectedStationID =
      initialSnapshot.stations.first(where: \.defaultStation)?.id
      ?? initialSnapshot.stations.first?.id
      ?? ""
  }

  var selectedStation: MobileStationSummary? {
    snapshot.station(id: selectedStationID)
  }

  var sessionsForSelectedStation: [MobileSessionSummary] {
    snapshot.sessions
      .filter { selectedStationID.isEmpty || $0.stationID == selectedStationID }
      .sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  var commandsForSelectedStation: [MobileCommandRecord] {
    snapshot.commands(for: selectedStationID)
  }

  var taskBoardForSelectedStation: [MobileTaskBoardSummary] {
    snapshot.taskBoardItems(for: selectedStationID)
  }

  func canQueueCommand(stationID: String) -> Bool {
    demoModeEnabled || syncClient(for: stationID) != nil
  }

  func load() async {
    if demoModeEnabled {
      snapshot = MobileDemoFixtures.snapshot()
      selectedStationID =
        snapshot.stations.first(where: \.defaultStation)?.id
        ?? snapshot.stations.first?.id
        ?? ""
      status = .demo
      return
    }
    do {
      let credentials = try await credentialStore.loadAll()
      var nextClients: [String: MobileCloudMirrorSyncClient] = [:]
      var validCredentials: [MobilePairedStationCredential] = []
      for credential in credentials {
        guard let identity = try await identityStore.load(id: credential.deviceIdentityID) else {
          continue
        }
        validCredentials.append(credential)
        nextClients[credential.stationID] = MobileCloudMirrorSyncClient(
          database: LiveMobileCloudMirrorDatabase(),
          cipher: MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation),
          deviceIdentity: identity,
          actorDeviceID: MobileCommandActorDeviceID.watchActorID(baseDeviceID: identity.id),
          commandKeyID: credential.commandKeyID
        )
      }
      guard !validCredentials.isEmpty else {
        applyCachedSnapshotIfAvailable()
        status = snapshot.stations.isEmpty ? .unpaired : .stale("Waiting for iPhone pairing.")
        return
      }
      syncClientsByStationID = nextClients
      defaultStationID =
        validCredentials.first(where: \.defaultStation)?.stationID
        ?? validCredentials.first?.stationID
      let scopedSnapshot = snapshot.keepingStationData(
        for: validCredentials.map(\.stationID),
        defaultStationID: defaultStationID
      )
      if scopedSnapshot != snapshot {
        snapshot = scopedSnapshot
        try? sharedSnapshotStore?.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
      }
      if selectedStationID.isEmpty || syncClientsByStationID[selectedStationID] == nil {
        selectedStationID = defaultStationID ?? ""
      }
      applyPairedStationPlaceholders(validCredentials)
      await refresh()
    } catch {
      status = .stale(mobileMirrorReadableErrorDescription(error))
    }
  }

  func loadTransferredPairings() async {
    demoModeEnabled = false
    defaultStationID = nil
    syncClientsByStationID = [:]
    status = .loading
    await load()
  }

  func syncClient(for stationID: String) -> MobileCloudMirrorSyncClient? {
    if let client = syncClientsByStationID[stationID] {
      return client
    }
    if stationID.isEmpty, let defaultStationID {
      return syncClientsByStationID[defaultStationID]
    }
    return nil
  }

  func isCurrentRefresh(_ generation: UInt64) -> Bool {
    generation == refreshGeneration
  }

  func nextRefreshGeneration() -> UInt64 {
    refreshGeneration &+= 1
    return refreshGeneration
  }

  /// Ask the iPhone to re-send current pairing material when the watch keeps settling to a
  /// "no mirror" stale state, throttled so a stuck watch does not request on every refresh.
  func requestFreshPairingMaterialIfThrottleAllows(now: Date = .now) {
    guard pairingRefreshThrottle.shouldRequest(now: now) else {
      return
    }
    requestFreshPairingMaterial?()
  }
}

import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import LocalAuthentication
import Observation
import WidgetKit

protocol MobileMonitorSyncClient: Sendable {
  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot?
  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand
  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt
}

actor LiveMobileMonitorSyncClient: MobileMonitorSyncClient {
  private let cloudMirrorSyncClient: MobileCloudMirrorSyncClient

  init(cloudMirrorSyncClient: MobileCloudMirrorSyncClient) {
    self.cloudMirrorSyncClient = cloudMirrorSyncClient
  }

  func fetchLatestSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    try await cloudMirrorSyncClient.fetchLatestSnapshot(stationID: stationID, now: now)
  }

  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand {
    try await cloudMirrorSyncClient.queueCommand(
      command,
      currentRevision: currentRevision,
      now: now
    )
  }

  func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    try await cloudMirrorSyncClient.cancelCommand(
      command,
      currentRevision: currentRevision,
      now: now
    )
  }
}

protocol MobileMonitorSyncClientFactory: Sendable {
  func makeSyncClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> any MobileMonitorSyncClient
}

struct LiveMobileMonitorSyncClientFactory: MobileMonitorSyncClientFactory {
  func makeSyncClient(
    credential: MobilePairedStationCredential,
    identity: MobileDeviceIdentity
  ) -> any MobileMonitorSyncClient {
    LiveMobileMonitorSyncClient(
      cloudMirrorSyncClient: MobileCloudMirrorSyncClient(
        database: LiveMobileCloudMirrorDatabase(),
        cipher: MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation),
        deviceIdentity: identity,
        commandKeyID: credential.commandKeyID
      )
    )
  }
}

protocol MobileMonitorCredentialPairer: Sendable {
  func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date
  ) async throws -> MobilePairedStationCredential
}

actor LiveMobileMonitorCredentialPairer: MobileMonitorCredentialPairer {
  private let coordinator: MobilePairingCoordinator<URLSessionMobilePairingTransport>

  init(
    identityStore: any MobileDeviceIdentityStore,
    credentialStore: any MobilePairedStationCredentialStore
  ) {
    coordinator = MobilePairingCoordinator(
      identityStore: identityStore,
      credentialStore: credentialStore,
      transport: URLSessionMobilePairingTransport()
    )
  }

  func pair(
    invitationURL: URL,
    deviceName: String,
    now: Date
  ) async throws -> MobilePairedStationCredential {
    try await coordinator.pair(invitationURL: invitationURL, deviceName: deviceName, now: now)
  }
}

enum MobileMonitorSyncStatus: Equatable {
  case unpaired
  case demo
  case pairing(String)
  case syncing
  case live(Date)
  case stale(String)
  case localNetworkDenied
  case iCloudAccountUnavailable
  case paired(String)
  case privacy(String)
  case commandQueued(Date)
  case commandCancelled(Date)
  case commandFailed(String)

  var title: String {
    switch self {
    case .unpaired: "No paired Mac"
    case .demo: "Demo station"
    case .pairing: "Pairing"
    case .syncing: "Syncing"
    case .live: "Live"
    case .stale: "Sync stale"
    case .localNetworkDenied: "Local Network blocked"
    case .iCloudAccountUnavailable: "iCloud sign-in needed"
    case .paired: "Mac paired"
    case .privacy: "Privacy updated"
    case .commandQueued: "Command queued"
    case .commandCancelled: "Command cancelled"
    case .commandFailed: "Command failed"
    }
  }

  var subtitle: String {
    switch self {
    case .unpaired:
      "Pair a Mac to enable live control."
    case .demo:
      "App Review demo data is active."
    case .pairing(let stationName):
      "Connecting to \(stationName)."
    case .syncing:
      "Fetching the latest encrypted mirror."
    case .live(let date):
      "Updated \(date.formatted(.relative(presentation: .numeric)))."
    case .stale(let reason):
      reason
    case .localNetworkDenied:
      "Allow Local Network access in iOS Settings, then scan the Mac QR code again."
    case .iCloudAccountUnavailable:
      "Sign in to iCloud in Settings to resume encrypted sync."
    case .paired(let stationName):
      "\(stationName) is trusted."
    case .privacy(let message):
      message
    case .commandQueued(let date):
      "Signed at \(date.formatted(.dateTime.hour().minute().second()))."
    case .commandCancelled(let date):
      "Cancelled at \(date.formatted(.dateTime.hour().minute().second()))."
    case .commandFailed(let reason):
      reason
    }
  }

  var systemImage: String {
    switch self {
    case .unpaired: "link.badge.plus"
    case .demo: "testtube.2"
    case .pairing: "qrcode.viewfinder"
    case .syncing: "arrow.triangle.2.circlepath"
    case .live: "checkmark.icloud"
    case .stale: "exclamationmark.icloud"
    case .localNetworkDenied: "wifi.slash"
    case .iCloudAccountUnavailable: "icloud.slash"
    case .paired: "key.horizontal"
    case .privacy: "checkmark.shield"
    case .commandQueued: "checkmark.seal"
    case .commandCancelled: "xmark.seal"
    case .commandFailed: "xmark.octagon"
    }
  }

  var opensAppSettingsForRecovery: Bool {
    if case .localNetworkDenied = self {
      return true
    }
    return false
  }

  var indicatesSyncFailure: Bool {
    switch self {
    case .stale, .localNetworkDenied, .iCloudAccountUnavailable:
      true
    case .unpaired, .demo, .pairing, .syncing, .live, .paired, .privacy,
      .commandQueued, .commandCancelled, .commandFailed:
      false
    }
  }
}

@MainActor
@Observable
final class MobileMonitorStore {
  var snapshot: MobileMirrorSnapshot
  var selectedStationID: String
  var demoModeEnabled: Bool
  var syncStatus: MobileMonitorSyncStatus
  var lastAuthenticationFailed = false
  var pairedCredentials: [MobilePairedStationCredential] = []
  var notificationSettings: MobileNotificationSettings
  var lastPrivacyInventory: MobileCloudMirrorRecordInventory?

  let identityStore: (any MobileDeviceIdentityStore)?
  let credentialStore: (any MobilePairedStationCredentialStore)?
  let syncClientFactory: any MobileMonitorSyncClientFactory
  let pairer: (any MobileMonitorCredentialPairer)?
  let privacyServiceProvider: @Sendable () -> any MobileCloudMirrorPrivacyManaging
  let sharedSnapshotStore: MobileSharedSnapshotStore?
  let watchPairingSyncer: (any MobileWatchPairingSyncing)?
  let liveActivityCoordinator: (any MobileCommandLiveActivityCoordinating)?
  let notificationDefaults: UserDefaults
  let notificationScheduler: any MobileNotificationScheduling
  let notificationDeliveryHistory: MobileNotificationDeliveryHistory
  let syncFetchTimeout: Duration
  var syncClientsByStationID: [String: any MobileMonitorSyncClient] = [:]
  var injectedSyncClient: (any MobileMonitorSyncClient)?
  var defaultStationID: String?
  var pairedIdentitiesByID: [String: MobileDeviceIdentity] = [:]
  var refreshGeneration: UInt64 = 0

  init(
    snapshot: MobileMirrorSnapshot? = nil,
    syncClient: (any MobileMonitorSyncClient)? = nil,
    defaultStationID: String? = nil,
    demoModeEnabled: Bool = false,
    identityStore: (any MobileDeviceIdentityStore)? = nil,
    credentialStore: (any MobilePairedStationCredentialStore)? = nil,
    syncClientFactory: any MobileMonitorSyncClientFactory = LiveMobileMonitorSyncClientFactory(),
    pairer: (any MobileMonitorCredentialPairer)? = nil,
    privacyServiceProvider: @escaping @Sendable () -> any MobileCloudMirrorPrivacyManaging = {
      MobileCloudMirrorPrivacyService(database: LiveMobileCloudMirrorDatabase())
    },
    sharedSnapshotStore: MobileSharedSnapshotStore? = MobileSharedSnapshotStore(),
    watchPairingSyncer: (any MobileWatchPairingSyncing)? = nil,
    liveActivityCoordinator: (any MobileCommandLiveActivityCoordinating)? =
      LiveMobileCommandLiveActivityCoordinator(),
    notificationDefaults: UserDefaults = .standard,
    notificationScheduler: any MobileNotificationScheduling = LiveMobileNotificationScheduler(),
    syncFetchTimeout: Duration = .seconds(20)
  ) {
    let cachedSnapshot = try? sharedSnapshotStore?.loadLatestSnapshot()
    let initialSnapshot =
      snapshot ?? (demoModeEnabled ? MobileDemoFixtures.snapshot() : cachedSnapshot ?? .empty())
    self.snapshot = initialSnapshot
    self.injectedSyncClient = syncClient
    self.defaultStationID = defaultStationID
    self.demoModeEnabled = demoModeEnabled
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.syncClientFactory = syncClientFactory
    self.pairer = pairer
    self.privacyServiceProvider = privacyServiceProvider
    self.sharedSnapshotStore = sharedSnapshotStore
    self.watchPairingSyncer = watchPairingSyncer
    self.liveActivityCoordinator = liveActivityCoordinator
    self.notificationDefaults = notificationDefaults
    self.notificationScheduler = notificationScheduler
    self.notificationDeliveryHistory = MobileNotificationDeliveryHistory(
      userDefaults: notificationDefaults
    )
    self.syncFetchTimeout = syncFetchTimeout
    self.notificationSettings = MobileNotificationSettings.load(from: notificationDefaults)
    self.syncStatus =
      if demoModeEnabled {
        .demo
      } else if let cachedSnapshot {
        .stale(
          "Showing last known mirror from "
            + "\(cachedSnapshot.generatedAt.formatted(.relative(presentation: .numeric)))."
        )
      } else {
        syncClient == nil ? .unpaired : .syncing
      }
    self.selectedStationID =
      defaultStationID
      ?? initialSnapshot.stations.first(where: \.defaultStation)?.id
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

  var reviewsNeedingMe: [MobileReviewSummary] {
    snapshot.reviews
      .filter(\.needsYou)
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  var taskBoardForSelectedStation: [MobileTaskBoardSummary] {
    snapshot.taskBoardItems(for: selectedStationID)
  }

  var commandsForSelectedStation: [MobileCommandRecord] {
    snapshot.commands(for: selectedStationID)
  }

  var canQueueCommands: Bool {
    demoModeEnabled || syncClient(for: selectedStationID) != nil
  }

  var mirroredPrivacyStationCount: Int {
    privacyStationIDs().count
  }

  var canManageMirroredPrivacyRecords: Bool {
    mirroredPrivacyStationCount > 0
  }

  func canQueueCommand(stationID: String) -> Bool {
    demoModeEnabled || syncClient(for: stationID) != nil
  }

  func setDemoMode(_ enabled: Bool) {
    guard demoModeEnabled != enabled else {
      return
    }
    demoModeEnabled = enabled
    Task {
      await refresh()
    }
  }

  func setNotificationCategory(_ category: MobileNotificationCategory, enabled: Bool) {
    notificationSettings.setEnabled(enabled, for: category)
    notificationSettings.save(to: notificationDefaults)
    if enabled {
      Task {
        await requestNotificationAuthorization()
      }
    }
  }

  func requestNotificationAuthorization() async {
    let granted = await notificationScheduler.requestAuthorization()
    syncStatus =
      granted
      ? .privacy("Notifications are enabled.")
      : .privacy("Notifications are disabled in iOS Settings.")
  }
}

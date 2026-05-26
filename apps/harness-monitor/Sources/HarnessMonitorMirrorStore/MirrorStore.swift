import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import Observation

/// The single mirror store shared by the iOS and watch apps. It owns the
/// decrypted snapshot, the live sync clients, and the command/queue flow.
/// Platform differences are expressed through the injected `profile`, the
/// optional collaborators (the watch passes none), and the sync-client factory
/// (the watch stamps its own actor id). This is a single unified class rather
/// than a base plus subclasses because the `@Observable` macro does not track
/// stored properties added by a subclass.
@MainActor
@Observable
public final class MirrorStore {
  public var snapshot: MobileMirrorSnapshot
  public var selectedStationID: String
  public var demoModeEnabled: Bool
  public var syncStatus: MirrorSyncStatus
  public var lastAuthenticationFailed = false
  public var pairedCredentials: [MobilePairedStationCredential] = []
  public var notificationSettings: MobileNotificationSettings
  public var lastPrivacyInventory: MobileCloudMirrorRecordInventory?

  /// Watch-only recovery hook: invoked (throttled) when a refresh keeps settling
  /// to a "no mirror" stale state, so the watch can ask the iPhone to re-send
  /// pairing material. The iPhone leaves this nil.
  @ObservationIgnored public var requestFreshPairingMaterial: (@Sendable () -> Void)?

  let identityStore: (any MobileDeviceIdentityStore)?
  let credentialStore: (any MobilePairedStationCredentialStore)?
  let syncClientFactory: any MobileMonitorSyncClientFactory
  let pairer: (any MobileMonitorCredentialPairer)?
  let privacyServiceProvider: @Sendable () -> any MobileCloudMirrorPrivacyManaging
  let sharedSnapshotStore: MobileSharedSnapshotStore?
  let watchPairingSyncer: (any MobileWatchPairingSyncing)?
  let liveActivityCoordinator: (any MobileCommandLiveActivityCoordinating)?
  let notificationDefaults: UserDefaults
  let notificationScheduler: (any MobileNotificationScheduling)?
  let notificationDeliveryHistory: MobileNotificationDeliveryHistory
  let syncFetchTimeout: Duration
  let profile: MirrorStoreProfile
  let authenticator: any MirrorAuthenticating
  var syncClientsByStationID: [String: any MobileMonitorSyncClient] = [:]
  var injectedSyncClient: (any MobileMonitorSyncClient)?
  var defaultStationID: String?
  var pairedIdentitiesByID: [String: MobileDeviceIdentity] = [:]
  @ObservationIgnored var isRefreshing = false
  @ObservationIgnored var pendingRefreshRequested = false
  @ObservationIgnored private var pairingRefreshThrottle = MobilePairingRefreshThrottle()

  public init(
    snapshot: MobileMirrorSnapshot? = nil,
    syncClient: (any MobileMonitorSyncClient)? = nil,
    defaultStationID: String? = nil,
    demoModeEnabled: Bool = false,
    profile: MirrorStoreProfile = .phone,
    identityStore: (any MobileDeviceIdentityStore)? = nil,
    credentialStore: (any MobilePairedStationCredentialStore)? = nil,
    syncClientFactory: any MobileMonitorSyncClientFactory = LiveMobileMonitorSyncClientFactory(),
    pairer: (any MobileMonitorCredentialPairer)? = nil,
    privacyServiceProvider: @escaping @Sendable () -> any MobileCloudMirrorPrivacyManaging = {
      MobileCloudMirrorPrivacyService(database: LiveMobileCloudMirrorDatabase())
    },
    sharedSnapshotStore: MobileSharedSnapshotStore? = MobileSharedSnapshotStore(),
    watchPairingSyncer: (any MobileWatchPairingSyncing)? = nil,
    liveActivityCoordinator: (any MobileCommandLiveActivityCoordinating)? = nil,
    notificationDefaults: UserDefaults = .standard,
    notificationScheduler: (any MobileNotificationScheduling)? = nil,
    syncFetchTimeout: Duration = .seconds(20),
    authenticator: any MirrorAuthenticating = LocalAuthenticationAuthenticator()
  ) {
    let cachedSnapshot = try? sharedSnapshotStore?.loadLatestSnapshot()
    let initialSnapshot =
      snapshot ?? (demoModeEnabled ? MobileDemoFixtures.snapshot() : cachedSnapshot ?? .empty())
    self.snapshot = initialSnapshot
    self.injectedSyncClient = syncClient
    self.defaultStationID = defaultStationID
    self.demoModeEnabled = demoModeEnabled
    self.profile = profile
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
    self.authenticator = authenticator
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

  public var selectedStation: MobileStationSummary? {
    snapshot.station(id: selectedStationID)
  }

  public var sessionsForSelectedStation: [MobileSessionSummary] {
    snapshot.sessions
      .filter { selectedStationID.isEmpty || $0.stationID == selectedStationID }
      .sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  public var reviewsNeedingMe: [MobileReviewSummary] {
    snapshot.reviews
      .filter(\.needsYou)
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  public var taskBoardForSelectedStation: [MobileTaskBoardSummary] {
    snapshot.taskBoardItems(for: selectedStationID)
  }

  public var reviewsForSelectedStation: [MobileReviewSummary] {
    snapshot.reviews(forStation: selectedStationID)
  }

  public var commandsForSelectedStation: [MobileCommandRecord] {
    snapshot.commands(for: selectedStationID)
  }

  public var canQueueCommands: Bool {
    demoModeEnabled || syncClient(for: selectedStationID) != nil
  }

  public var mirroredPrivacyStationCount: Int {
    privacyStationIDs().count
  }

  public var canManageMirroredPrivacyRecords: Bool {
    mirroredPrivacyStationCount > 0
  }

  public func canQueueCommand(stationID: String) -> Bool {
    demoModeEnabled || syncClient(for: stationID) != nil
  }

  public func setDemoMode(_ enabled: Bool) {
    guard demoModeEnabled != enabled else {
      return
    }
    demoModeEnabled = enabled
    Task {
      await refresh()
    }
  }

  public func setNotificationCategory(_ category: MobileNotificationCategory, enabled: Bool) {
    notificationSettings.setEnabled(enabled, for: category)
    notificationSettings.save(to: notificationDefaults)
    if enabled {
      Task {
        await requestNotificationAuthorization()
      }
    }
  }

  public func requestNotificationAuthorization() async {
    guard let notificationScheduler else {
      return
    }
    let granted = await notificationScheduler.requestAuthorization()
    syncStatus =
      granted
      ? .privacy("Notifications are enabled.")
      : .privacy("Notifications are disabled in iOS Settings.")
  }

  /// Asks the iPhone (via the watch hook) to re-send pairing material, throttled
  /// so a stuck watch cannot request on every refresh. A no-op on the iPhone,
  /// where `requestFreshPairingMaterial` is nil.
  func requestFreshPairingMaterialIfThrottleAllows(now: Date = .now) {
    guard pairingRefreshThrottle.shouldRequest(now: now) else {
      return
    }
    requestFreshPairingMaterial?()
  }
}

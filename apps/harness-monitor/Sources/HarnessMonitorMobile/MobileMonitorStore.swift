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
}

private func mobileMonitorSyncStatus(for error: any Error) -> MobileMonitorSyncStatus {
  if mobileMonitorErrorIsLocalNetworkDenied(error) {
    return .localNetworkDenied
  }
  return .stale(mobileMonitorReadableErrorDescription(error))
}

private func mobileMonitorReadableErrorDescription(_ error: any Error) -> String {
  let description = (error as NSError).localizedDescription
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return description.isEmpty ? String(describing: error) : description
}

private func mobileMonitorErrorIsLocalNetworkDenied(_ error: any Error) -> Bool {
  mobileMonitorNSErrorTreeContainsLocalNetworkDenied(error as NSError)
}

private func mobileMonitorNSErrorTreeContainsLocalNetworkDenied(
  _ error: NSError,
  depth: Int = 0
) -> Bool {
  guard depth < 4 else {
    return false
  }
  let searchableText = [
    error.localizedDescription,
    String(describing: error.userInfo),
  ].joined(separator: " ")
  if searchableText.localizedCaseInsensitiveContains("Local network prohibited") {
    return true
  }
  for value in error.userInfo.values {
    if let nestedError = value as? NSError,
      mobileMonitorNSErrorTreeContainsLocalNetworkDenied(nestedError, depth: depth + 1)
    {
      return true
    }
    if String(describing: value).localizedCaseInsensitiveContains("Local network prohibited") {
      return true
    }
  }
  return false
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

  private let identityStore: (any MobileDeviceIdentityStore)?
  private let credentialStore: (any MobilePairedStationCredentialStore)?
  private let syncClientFactory: any MobileMonitorSyncClientFactory
  private let pairer: (any MobileMonitorCredentialPairer)?
  private let privacyService: any MobileCloudMirrorPrivacyManaging
  private let sharedSnapshotStore: MobileSharedSnapshotStore?
  private let watchPairingSyncer: (any MobileWatchPairingSyncing)?
  private let liveActivityCoordinator: (any MobileCommandLiveActivityCoordinating)?
  private let notificationDefaults: UserDefaults
  private let notificationScheduler: any MobileNotificationScheduling
  private let notificationDeliveryHistory: MobileNotificationDeliveryHistory
  private var syncClientsByStationID: [String: any MobileMonitorSyncClient] = [:]
  private var injectedSyncClient: (any MobileMonitorSyncClient)?
  private var defaultStationID: String?

  init(
    snapshot: MobileMirrorSnapshot? = nil,
    syncClient: (any MobileMonitorSyncClient)? = nil,
    defaultStationID: String? = nil,
    demoModeEnabled: Bool = false,
    identityStore: (any MobileDeviceIdentityStore)? = nil,
    credentialStore: (any MobilePairedStationCredentialStore)? = nil,
    syncClientFactory: any MobileMonitorSyncClientFactory = LiveMobileMonitorSyncClientFactory(),
    pairer: (any MobileMonitorCredentialPairer)? = nil,
    privacyService: any MobileCloudMirrorPrivacyManaging =
      MobileCloudMirrorPrivacyService(database: LiveMobileCloudMirrorDatabase()),
    sharedSnapshotStore: MobileSharedSnapshotStore? = MobileSharedSnapshotStore(),
    watchPairingSyncer: (any MobileWatchPairingSyncing)? = nil,
    liveActivityCoordinator: (any MobileCommandLiveActivityCoordinating)? =
      LiveMobileCommandLiveActivityCoordinator(),
    notificationDefaults: UserDefaults = .standard,
    notificationScheduler: any MobileNotificationScheduling = LiveMobileNotificationScheduler()
  ) {
    let initialSnapshot = snapshot ?? (demoModeEnabled ? MobileDemoFixtures.snapshot() : .empty())
    self.snapshot = initialSnapshot
    self.injectedSyncClient = syncClient
    self.defaultStationID = defaultStationID
    self.demoModeEnabled = demoModeEnabled
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.syncClientFactory = syncClientFactory
    self.pairer = pairer
    self.privacyService = privacyService
    self.sharedSnapshotStore = sharedSnapshotStore
    self.watchPairingSyncer = watchPairingSyncer
    self.liveActivityCoordinator = liveActivityCoordinator
    self.notificationDefaults = notificationDefaults
    self.notificationScheduler = notificationScheduler
    self.notificationDeliveryHistory = MobileNotificationDeliveryHistory(
      userDefaults: notificationDefaults
    )
    self.notificationSettings = MobileNotificationSettings.load(from: notificationDefaults)
    self.syncStatus =
      demoModeEnabled ? .demo : (syncClient == nil ? .unpaired : .syncing)
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

  var commandsForSelectedStation: [MobileCommandRecord] {
    snapshot.commands(for: selectedStationID)
  }

  var canQueueCommands: Bool {
    demoModeEnabled || syncClient(for: selectedStationID) != nil
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

  func refresh() async {
    if demoModeEnabled {
      refreshDemoData()
      syncStatus = .demo
      return
    }
    guard
      let stationID = preferredLiveStationID(),
      let syncClient = syncClient(for: stationID)
    else {
      snapshot = .empty()
      selectedStationID = ""
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      syncStatus = .unpaired
      return
    }

    syncStatus = .syncing
    do {
      guard let fetched = try await syncClient.fetchLatestSnapshot(stationID: stationID, now: .now)
      else {
        syncStatus = .stale("No encrypted mirror snapshot found.")
        return
      }
      let previous = applySnapshot(fetched, preferredStationID: stationID)
      syncStatus = .live(fetched.generatedAt)
      await scheduleNotifications(previous: previous, next: fetched)
    } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
      syncStatus =
        .stale(
          "Last encrypted mirror expired \(expiresAt.formatted(.relative(presentation: .numeric)))."
        )
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
    }
  }

  func refreshDemoData() {
    _ = applySnapshot(MobileDemoFixtures.snapshot(), preferredStationID: selectedStationID)
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
      demoModeEnabled = false
      syncStatus = .pairing(invitation.stationName)
      let credential = try await pairer.pair(
        invitationURL: invitationURL,
        deviceName: deviceName,
        now: .now
      )
      try await rebuildSyncClients(preferredStationID: credential.stationID)
      syncStatus = .paired(credential.stationName)
      await refresh()
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

  func exportMirroredRecords() async -> URL? {
    guard let stationID = preferredLiveStationID() else {
      syncStatus = .unpaired
      return nil
    }
    do {
      let data = try await privacyService.exportRecords(stationID: stationID, now: .now)
      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("harness-monitor-\(stationID)-mirror")
        .appendingPathExtension("json")
      try data.write(to: fileURL, options: [.atomic])
      syncStatus = .privacy("Exported encrypted mirror records.")
      return fileURL
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
      return nil
    }
  }

  func deleteCloudKitMirror() async {
    guard let stationID = preferredLiveStationID() else {
      syncStatus = .unpaired
      return
    }
    do {
      let deletedCount = try await privacyService.deleteRecords(stationID: stationID)
      snapshot = .empty()
      selectedStationID = stationID
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      syncStatus = .privacy("Deleted \(deletedCount) mirrored records.")
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
    }
  }

  func queueCommand(from attention: MobileAttentionItem) async {
    guard let kind = attention.commandKind, let target = attention.target else {
      return
    }
    let draft = MobileCommandDraft(
      kind: kind,
      confirmationText: attention.title,
      auditReason: kind == .pullRequestMerge ? "Confirmed from iPhone." : nil,
      target: target,
      payload: attention.commandPayload
    )
    await queueCommand(draft)
  }

  func queueCommand(_ draft: MobileCommandDraft) async {
    let now = Date()
    let command: MobileCommandRecord
    do {
      command =
        try draft
        .makeCommand(
          id: "command-\(UUID().uuidString)",
          actorDeviceID: "",
          createdAt: now
        )
        .validatingFreshState(currentRevision: snapshot.revision)
    } catch {
      syncStatus = .commandFailed(String(describing: error))
      return
    }

    let authenticated = await authenticate(reason: command.confirmationText)
    guard authenticated else {
      lastAuthenticationFailed = true
      return
    }

    if demoModeEnabled {
      var command = command
      command.status = .queued
      command.actorDeviceID = "device-demo-phone"
      snapshot.commands.insert(command, at: 0)
      selectedStationID = command.stationID
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      syncStatus = .demo
      return
    }
    guard let syncClient = syncClient(for: command.stationID) else {
      syncStatus = .unpaired
      return
    }
    do {
      let queued = try await syncClient.queueCommand(
        command,
        currentRevision: snapshot.revision,
        now: now
      )
      snapshot.commands.insert(queued.signedCommand.command, at: 0)
      selectedStationID = command.stationID
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      syncStatus = .commandQueued(now)
    } catch {
      syncStatus = .commandFailed(String(describing: error))
    }
  }

  func retry(_ command: MobileCommandRecord) {
    guard demoModeEnabled else {
      syncStatus = .commandFailed("Retry needs a fresh signed command.")
      return
    }
    guard let index = snapshot.commands.firstIndex(where: { $0.id == command.id }) else {
      return
    }
    snapshot.commands[index].status = .queued
    snapshot.commands[index].updatedAt = .now
    snapshot.commands[index].expiresAt = Date().addingTimeInterval(15 * 60)
    snapshot.commands[index].receipt = nil
    persistSharedSnapshot(snapshot)
    reconcileLiveActivity(snapshot)
  }

  func cancel(_ command: MobileCommandRecord) async {
    let now = Date()
    guard command.status == .queued else {
      syncStatus = .commandFailed("Only queued commands can be cancelled safely.")
      return
    }

    if demoModeEnabled {
      applyCancellationReceipt(
        MobileCommandReceipt(
          commandID: command.id,
          stationID: command.stationID,
          status: .cancelled,
          message: "Cancelled in demo mode.",
          receivedAt: now,
          completedAt: now,
          executionRevision: snapshot.revision
        ),
        fallbackCommand: command
      )
      syncStatus = .commandCancelled(now)
      return
    }
    guard let syncClient = syncClient(for: command.stationID) else {
      syncStatus = .unpaired
      return
    }
    do {
      let receipt = try await syncClient.cancelCommand(
        command,
        currentRevision: snapshot.revision,
        now: now
      )
      applyCancellationReceipt(receipt, fallbackCommand: command)
      syncStatus = .commandCancelled(now)
    } catch {
      syncStatus = .commandFailed(String(describing: error))
    }
  }

  private func applyCancellationReceipt(
    _ receipt: MobileCommandReceipt,
    fallbackCommand command: MobileCommandRecord
  ) {
    guard let index = snapshot.commands.firstIndex(where: { $0.id == command.id }) else {
      var cancelledCommand = command
      cancelledCommand.status = receipt.status
      cancelledCommand.receipt = receipt
      cancelledCommand.updatedAt = receipt.completedAt ?? receipt.receivedAt
      snapshot.commands.insert(cancelledCommand, at: 0)
      selectedStationID = command.stationID
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      return
    }
    snapshot.commands[index].status = receipt.status
    snapshot.commands[index].receipt = receipt
    snapshot.commands[index].updatedAt = receipt.completedAt ?? receipt.receivedAt
    persistSharedSnapshot(snapshot)
    reconcileLiveActivity(snapshot)
  }

  private func applySnapshot(
    _ nextSnapshot: MobileMirrorSnapshot,
    preferredStationID: String
  ) -> MobileMirrorSnapshot {
    let previousSnapshot = snapshot
    snapshot = nextSnapshot
    persistSharedSnapshot(nextSnapshot)
    if snapshot.stations.contains(where: { $0.id == preferredStationID }) {
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

  private func scheduleNotifications(
    previous: MobileMirrorSnapshot?,
    next: MobileMirrorSnapshot
  ) async {
    let plannedRequests = MobileNotificationPlanner.requests(
      previous: previous,
      next: next,
      settings: notificationSettings
    )
    let newRequests = notificationDeliveryHistory.unrecordedRequests(plannedRequests)
    let scheduledRequestIDs = await notificationScheduler.schedule(newRequests)
    notificationDeliveryHistory.recordDeliveredRequestIDs(scheduledRequestIDs)
  }

  private func persistSharedSnapshot(_ nextSnapshot: MobileMirrorSnapshot) {
    do {
      try sharedSnapshotStore?.save(nextSnapshot)
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      syncStatus = .stale("Could not update widgets: \(String(describing: error))")
    }
  }

  private func reconcileLiveActivity(_ nextSnapshot: MobileMirrorSnapshot) {
    let preferredStationID = selectedStationID
    Task { [liveActivityCoordinator] in
      await liveActivityCoordinator?.reconcile(
        snapshot: nextSnapshot,
        preferredStationID: preferredStationID
      )
    }
  }

  private func rebuildSyncClients(preferredStationID: String? = nil) async throws {
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
    syncClientsByStationID = nextClients
    defaultStationID =
      preferredStationID
      ?? validCredentials.first(where: \.defaultStation)?.stationID
      ?? validCredentials.first?.stationID
    if let defaultStationID, !defaultStationID.isEmpty {
      selectedStationID = defaultStationID
    }
    await watchPairingSyncer?.publish(
      identities: identitiesByID.values.sorted { $0.id < $1.id },
      credentials: validCredentials,
      exportedAt: .now
    )
  }

  private func preferredLiveStationID() -> String? {
    if !selectedStationID.isEmpty {
      return selectedStationID
    }
    return defaultStationID
  }

  private func syncClient(for stationID: String) -> (any MobileMonitorSyncClient)? {
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

  private func authenticate(reason: String) async -> Bool {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      return false
    }
    return await withCheckedContinuation { continuation in
      context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason
      ) { success, _ in
        continuation.resume(returning: success)
      }
    }
  }
}

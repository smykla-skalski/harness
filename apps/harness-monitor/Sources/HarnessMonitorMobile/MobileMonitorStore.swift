import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import LocalAuthentication
import Observation

protocol MobileMonitorSyncClient: Sendable {
  func fetchLatestSnapshot(stationID: String, now: Date) async throws -> MobileMirrorSnapshot?
  func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand
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
  case paired(String)
  case commandQueued(Date)
  case commandFailed(String)

  var title: String {
    switch self {
    case .unpaired: "No paired Mac"
    case .demo: "Demo station"
    case .pairing: "Pairing"
    case .syncing: "Syncing"
    case .live: "Live"
    case .stale: "Sync stale"
    case .paired: "Mac paired"
    case .commandQueued: "Command queued"
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
    case .paired(let stationName):
      "\(stationName) is trusted."
    case .commandQueued(let date):
      "Signed at \(date.formatted(.dateTime.hour().minute().second()))."
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
    case .paired: "key.horizontal"
    case .commandQueued: "checkmark.seal"
    case .commandFailed: "xmark.octagon"
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

  private let identityStore: (any MobileDeviceIdentityStore)?
  private let credentialStore: (any MobilePairedStationCredentialStore)?
  private let syncClientFactory: any MobileMonitorSyncClientFactory
  private let pairer: (any MobileMonitorCredentialPairer)?
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
    pairer: (any MobileMonitorCredentialPairer)? = nil
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

  func setDemoMode(_ enabled: Bool) {
    guard demoModeEnabled != enabled else {
      return
    }
    demoModeEnabled = enabled
    Task {
      await refresh()
    }
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
      applySnapshot(fetched, preferredStationID: stationID)
      syncStatus = .live(fetched.generatedAt)
    } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
      syncStatus =
        .stale(
          "Last encrypted mirror expired \(expiresAt.formatted(.relative(presentation: .numeric)))."
        )
    } catch {
      syncStatus = .stale(String(describing: error))
    }
  }

  func refreshDemoData() {
    applySnapshot(MobileDemoFixtures.snapshot(), preferredStationID: selectedStationID)
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
      syncStatus = .stale(String(describing: error))
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
      syncStatus = .stale(String(describing: error))
    }
  }

  func queueCommand(from attention: MobileAttentionItem) async {
    guard let kind = attention.commandKind, let target = attention.target else {
      return
    }
    let authenticated = await authenticate(reason: kind.title)
    guard authenticated else {
      lastAuthenticationFailed = true
      return
    }

    let now = Date()
    let risk: MobileCommandRisk = kind == .pullRequestMerge ? .destructive : .high
    var command = MobileCommandRecord(
      id: "command-\(UUID().uuidString)",
      stationID: target.stationID,
      kind: kind,
      risk: risk,
      status: .draft,
      title: kind.title,
      confirmationText: attention.title,
      auditReason: risk == .destructive ? "Confirmed from iPhone." : nil,
      target: target,
      actorDeviceID: "",
      createdAt: now,
      expiresAt: now.addingTimeInterval(15 * 60),
      updatedAt: now
    )
    if demoModeEnabled {
      command.status = .queued
      command.actorDeviceID = "device-demo-phone"
      snapshot.commands.insert(command, at: 0)
      selectedStationID = target.stationID
      syncStatus = .demo
      return
    }
    guard let syncClient = syncClient(for: target.stationID) else {
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
      selectedStationID = target.stationID
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
  }

  func cancel(_ command: MobileCommandRecord) {
    guard demoModeEnabled else {
      syncStatus = .commandFailed("Remote cancellation is not available for this command.")
      return
    }
    guard let index = snapshot.commands.firstIndex(where: { $0.id == command.id }) else {
      return
    }
    snapshot.commands[index].status = .cancelled
    snapshot.commands[index].updatedAt = .now
  }

  private func applySnapshot(_ nextSnapshot: MobileMirrorSnapshot, preferredStationID: String) {
    snapshot = nextSnapshot
    if snapshot.stations.contains(where: { $0.id == preferredStationID }) {
      selectedStationID = preferredStationID
    } else {
      selectedStationID =
        snapshot.stations.first(where: \.defaultStation)?.id
        ?? snapshot.stations.first?.id
        ?? ""
    }
  }

  private func rebuildSyncClients(preferredStationID: String? = nil) async throws {
    guard let identityStore, let credentialStore else {
      return
    }
    let credentials = try await credentialStore.loadAll()
    var nextClients: [String: any MobileMonitorSyncClient] = [:]
    for credential in credentials {
      guard let identity = try await identityStore.load(id: credential.deviceIdentityID) else {
        continue
      }
      nextClients[credential.stationID] = syncClientFactory.makeSyncClient(
        credential: credential,
        identity: identity
      )
    }
    pairedCredentials = credentials
    syncClientsByStationID = nextClients
    defaultStationID =
      preferredStationID
      ?? credentials.first(where: \.defaultStation)?.stationID
      ?? credentials.first?.stationID
    if let defaultStationID, !defaultStationID.isEmpty {
      selectedStationID = defaultStationID
    }
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

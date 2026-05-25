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
  private let sharedSnapshotStore: MobileSharedSnapshotStore?
  private let syncFetchTimeout: Duration
  private var syncClientsByStationID: [String: MobileCloudMirrorSyncClient] = [:]
  private var defaultStationID: String?
  private var refreshGeneration: UInt64 = 0

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
      snapshot ?? cachedSnapshot ?? (demoModeEnabled ? MobileDemoFixtures.snapshot() : .empty())
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
      status = .stale(String(describing: error))
    }
  }

  func loadTransferredPairings() async {
    demoModeEnabled = false
    defaultStationID = nil
    syncClientsByStationID = [:]
    status = .loading
    await load()
  }

  func refresh() async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    if demoModeEnabled {
      snapshot = MobileDemoFixtures.snapshot()
      status = .demo
      return
    }
    let stationIDs = stationIDsForRefresh()
    guard !stationIDs.isEmpty else {
      status = .unpaired
      return
    }
    status = .loading
    let preferredStationID = preferredLiveStationID() ?? stationIDs[0]
    var aggregateSnapshot = snapshot
    var latestGeneratedAt: Date?
    var selectedStationRefreshed = false
    var failureReason: String?

    for stationID in stationIDs {
      guard let syncClient = syncClient(for: stationID) else {
        continue
      }
      do {
        guard
          let nextSnapshot = try await fetchLatestSnapshot(
            using: syncClient,
            stationID: stationID
          )
        else {
          guard isCurrentRefresh(generation) else {
            return
          }
          failureReason = "No mirror snapshot"
          continue
        }
        guard isCurrentRefresh(generation) else {
          return
        }
        aggregateSnapshot = aggregateSnapshot.mergingStationSnapshot(
          nextSnapshot,
          stationID: stationID,
          defaultStationID: defaultStationID
        )
        latestGeneratedAt = max(
          latestGeneratedAt ?? nextSnapshot.generatedAt,
          nextSnapshot.generatedAt
        )
        selectedStationRefreshed = stationID == preferredStationID || selectedStationRefreshed
      } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
        guard isCurrentRefresh(generation) else {
          return
        }
        failureReason = "Expired \(expiresAt.formatted(.relative(presentation: .numeric)))"
      } catch {
        guard isCurrentRefresh(generation) else {
          return
        }
        failureReason = String(describing: error)
      }
    }

    guard isCurrentRefresh(generation) else {
      return
    }
    guard let latestGeneratedAt else {
      applyCachedSnapshotIfAvailable()
      status = .stale(failureReason ?? "No mirror snapshot")
      return
    }

    applyAggregateSnapshot(aggregateSnapshot, preferredStationID: preferredStationID)
    status =
      selectedStationRefreshed
      ? .live(latestGeneratedAt)
      : .stale(failureReason ?? "Selected station did not refresh")
  }

  private func fetchLatestSnapshot(
    using syncClient: MobileCloudMirrorSyncClient,
    stationID: String
  ) async throws -> MobileMirrorSnapshot? {
    try await MobileAsyncTimeout.run(
      timeout: syncFetchTimeout,
      timeoutError: { MobileMirrorRefreshTimeout() },
      operation: {
        try await syncClient.fetchLatestSnapshot(stationID: stationID)
      }
    )
  }

  func queueCommand(from attention: MobileAttentionItem) async {
    guard let kind = attention.commandKind, let target = attention.target else {
      return
    }
    let draft = MobileCommandDraft(
      kind: kind,
      confirmationText: attention.title,
      auditReason: kind == .pullRequestMerge ? "Confirmed from Apple Watch." : nil,
      target: target,
      payload: attention.commandPayload,
      expiresAfter: 10 * 60
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
          id: "watch-command-\(UUID().uuidString)",
          actorDeviceID: "",
          createdAt: now
        )
        .validatingFreshState(currentRevision: snapshot.revision)
    } catch {
      status = .commandFailed(String(describing: error))
      return
    }

    guard await authenticate(reason: command.confirmationText) else {
      status = .commandFailed("Authentication cancelled")
      return
    }
    if demoModeEnabled {
      var command = command
      command.status = .queued
      command.actorDeviceID = "device-demo-watch"
      snapshot.commands.insert(command, at: 0)
      selectedStationID = command.stationID
      status = .demo
      return
    }
    guard let syncClient = syncClient(for: command.stationID) else {
      status = .unpaired
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
      status = .commandQueued(now)
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      status = .commandFailed(String(describing: error))
    }
  }

  func cancel(_ command: MobileCommandRecord) async {
    let now = Date()
    guard command.status == .queued else {
      status = .commandFailed("Only queued commands can be cancelled safely.")
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
      status = .commandCancelled(now)
      return
    }
    guard let syncClient = syncClient(for: command.stationID) else {
      status = .unpaired
      return
    }
    do {
      let receipt = try await syncClient.cancelCommand(
        command,
        currentRevision: snapshot.revision,
        now: now
      )
      applyCancellationReceipt(receipt, fallbackCommand: command)
      status = .commandCancelled(now)
    } catch {
      status = .commandFailed(String(describing: error))
    }
  }

  func retry(_ command: MobileCommandRecord) async {
    do {
      let draft = try command.retryDraft(currentRevision: snapshot.revision, expiresAfter: 10 * 60)
      await queueCommand(draft)
    } catch {
      status = .commandFailed(String(describing: error))
    }
  }

  private func applyCancellationReceipt(
    _ receipt: MobileCommandReceipt,
    fallbackCommand command: MobileCommandRecord
  ) {
    if let index = snapshot.commands.firstIndex(where: { $0.id == command.id }) {
      snapshot.commands[index].status = receipt.status
      snapshot.commands[index].receipt = receipt
      snapshot.commands[index].updatedAt = receipt.completedAt ?? receipt.receivedAt
    } else {
      var cancelledCommand = command
      cancelledCommand.status = receipt.status
      cancelledCommand.receipt = receipt
      cancelledCommand.updatedAt = receipt.completedAt ?? receipt.receivedAt
      snapshot.commands.insert(cancelledCommand, at: 0)
    }
    selectedStationID = command.stationID
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func preferredLiveStationID() -> String? {
    if !selectedStationID.isEmpty {
      return selectedStationID
    }
    return defaultStationID
  }

  private func stationIDsForRefresh() -> [String] {
    let stationIDs = syncClientsByStationID.keys.sorted()
    guard !stationIDs.isEmpty else {
      guard let stationID = preferredLiveStationID() else {
        return []
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

  private func applyCachedSnapshotIfAvailable() {
    guard let cachedSnapshot = try? sharedSnapshotStore?.loadLatestSnapshot() else {
      return
    }
    snapshot = cachedSnapshot
    if selectedStationID.isEmpty || snapshot.station(id: selectedStationID) == nil {
      selectedStationID =
        snapshot.stations.first(where: \.defaultStation)?.id
        ?? snapshot.stations.first?.id
        ?? ""
    }
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func applyAggregateSnapshot(
    _ nextSnapshot: MobileMirrorSnapshot,
    preferredStationID: String?
  ) {
    snapshot = nextSnapshot
    try? sharedSnapshotStore?.save(nextSnapshot)
    if let preferredStationID, snapshot.stations.contains(where: { $0.id == preferredStationID }) {
      selectedStationID = preferredStationID
    } else {
      selectedStationID =
        snapshot.stations.first(where: \.defaultStation)?.id
        ?? snapshot.stations.first?.id
        ?? ""
    }
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func isCurrentRefresh(_ generation: UInt64) -> Bool {
    generation == refreshGeneration
  }

  private func applyPairedStationPlaceholders(
    _ credentials: [MobilePairedStationCredential],
    now: Date = .now
  ) {
    let changed = snapshot.ensurePairedStationPlaceholders(
      for: credentials,
      defaultStationID: defaultStationID,
      now: now
    )
    if selectedStationID.isEmpty {
      selectedStationID = defaultStationID ?? snapshot.stations.first?.id ?? ""
    }
    guard changed else {
      return
    }
    try? sharedSnapshotStore?.save(snapshot)
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func syncClient(for stationID: String) -> MobileCloudMirrorSyncClient? {
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
      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
        continuation.resume(returning: success)
      }
    }
  }
}

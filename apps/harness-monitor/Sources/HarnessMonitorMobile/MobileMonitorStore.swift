import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
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

enum MobileMonitorSyncStatus: Equatable {
  case unpaired
  case demo
  case syncing
  case live(Date)
  case stale(String)
  case commandQueued(Date)
  case commandFailed(String)

  var title: String {
    switch self {
    case .unpaired: "No paired Mac"
    case .demo: "Demo station"
    case .syncing: "Syncing"
    case .live: "Live"
    case .stale: "Sync stale"
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
    case .syncing:
      "Fetching the latest encrypted mirror."
    case .live(let date):
      "Updated \(date.formatted(.relative(presentation: .numeric)))."
    case .stale(let reason):
      reason
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
    case .syncing: "arrow.triangle.2.circlepath"
    case .live: "checkmark.icloud"
    case .stale: "exclamationmark.icloud"
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

  private let syncClient: (any MobileMonitorSyncClient)?
  private let defaultStationID: String?

  init(
    snapshot: MobileMirrorSnapshot? = nil,
    syncClient: (any MobileMonitorSyncClient)? = nil,
    defaultStationID: String? = nil,
    demoModeEnabled: Bool = false
  ) {
    let initialSnapshot = snapshot ?? (demoModeEnabled ? MobileDemoFixtures.snapshot() : .empty())
    self.snapshot = initialSnapshot
    self.syncClient = syncClient
    self.defaultStationID = defaultStationID
    self.demoModeEnabled = demoModeEnabled
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
    demoModeEnabled || syncClient != nil
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
    guard let syncClient else {
      snapshot = .empty()
      selectedStationID = ""
      syncStatus = .unpaired
      return
    }
    let stationID = selectedStationID.isEmpty ? defaultStationID ?? "" : selectedStationID
    guard !stationID.isEmpty else {
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
    guard let syncClient else {
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

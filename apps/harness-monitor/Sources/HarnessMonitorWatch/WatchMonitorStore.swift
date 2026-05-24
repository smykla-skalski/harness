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
  case commandFailed(String)

  var title: String {
    switch self {
    case .loading: "Syncing"
    case .demo: "Demo station"
    case .live: "Live"
    case .unpaired: "No paired Mac"
    case .stale: "Stale"
    case .commandQueued: "Command queued"
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

  private let identityStore: any MobileDeviceIdentityStore
  private let credentialStore: any MobilePairedStationCredentialStore
  private var syncClient: MobileCloudMirrorSyncClient?
  private var stationID: String?

  init(
    snapshot: MobileMirrorSnapshot? = nil,
    demoModeEnabled: Bool = false,
    identityStore: any MobileDeviceIdentityStore = KeychainMobileDeviceIdentityStore(),
    credentialStore: any MobilePairedStationCredentialStore =
      KeychainMobilePairedStationCredentialStore()
  ) {
    self.demoModeEnabled = demoModeEnabled
    self.snapshot = snapshot ?? (demoModeEnabled ? MobileDemoFixtures.snapshot() : .empty())
    self.identityStore = identityStore
    self.credentialStore = credentialStore
    self.status = demoModeEnabled ? .demo : .loading
  }

  func load() async {
    if demoModeEnabled {
      snapshot = MobileDemoFixtures.snapshot()
      status = .demo
      return
    }
    do {
      let credentials = try await credentialStore.loadAll()
      guard
        let credential = credentials.first(where: \.defaultStation) ?? credentials.first,
        let identity = try await identityStore.load(id: credential.deviceIdentityID)
      else {
        snapshot = MobileDemoFixtures.snapshot()
        demoModeEnabled = true
        status = .demo
        return
      }
      stationID = credential.stationID
      syncClient = MobileCloudMirrorSyncClient(
        database: LiveMobileCloudMirrorDatabase(),
        cipher: MobilePayloadCipher(rawKey: credential.symmetricKeyRawRepresentation),
        deviceIdentity: identity,
        commandKeyID: credential.commandKeyID
      )
      await refresh()
    } catch {
      status = .stale(String(describing: error))
    }
  }

  func refresh() async {
    if demoModeEnabled {
      snapshot = MobileDemoFixtures.snapshot()
      status = .demo
      return
    }
    guard let syncClient, let stationID else {
      status = .unpaired
      return
    }
    status = .loading
    do {
      guard let nextSnapshot = try await syncClient.fetchLatestSnapshot(stationID: stationID) else {
        status = .stale("No mirror snapshot")
        return
      }
      snapshot = nextSnapshot
      status = .live(nextSnapshot.generatedAt)
      WidgetCenter.shared.reloadAllTimelines()
    } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
      status = .stale("Expired \(expiresAt.formatted(.relative(presentation: .numeric)))")
    } catch {
      status = .stale(String(describing: error))
    }
  }

  func queueCommand(from attention: MobileAttentionItem) async {
    guard let kind = attention.commandKind, let target = attention.target else {
      return
    }
    guard await authenticate(reason: kind.title) else {
      status = .commandFailed("Authentication cancelled")
      return
    }
    let now = Date()
    let risk: MobileCommandRisk = kind == .pullRequestMerge ? .destructive : .high
    var command = MobileCommandRecord(
      id: "watch-command-\(UUID().uuidString)",
      stationID: target.stationID,
      kind: kind,
      risk: risk,
      status: .draft,
      title: kind.title,
      confirmationText: attention.title,
      auditReason: risk == .destructive ? "Confirmed from Apple Watch." : nil,
      target: target,
      payload: attention.commandPayload,
      actorDeviceID: "",
      createdAt: now,
      expiresAt: now.addingTimeInterval(10 * 60),
      updatedAt: now
    )
    if demoModeEnabled {
      command.status = .queued
      command.actorDeviceID = "device-demo-watch"
      snapshot.commands.insert(command, at: 0)
      status = .demo
      return
    }
    guard let syncClient else {
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
      status = .commandQueued(now)
      WidgetCenter.shared.reloadAllTimelines()
    } catch {
      status = .commandFailed(String(describing: error))
    }
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

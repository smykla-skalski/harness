import Foundation
import HarnessMonitorCore
import LocalAuthentication
import Observation

@MainActor
@Observable
final class MobileMonitorStore {
  var snapshot: MobileMirrorSnapshot
  var selectedStationID: String
  var demoModeEnabled = true
  var lastAuthenticationFailed = false

  init(snapshot: MobileMirrorSnapshot = MobileDemoFixtures.snapshot()) {
    self.snapshot = snapshot
    self.selectedStationID =
      snapshot.stations.first(where: \.defaultStation)?.id
      ?? snapshot.stations.first?.id
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

  func refreshDemoData() {
    snapshot = MobileDemoFixtures.snapshot()
    if !snapshot.stations.contains(where: { $0.id == selectedStationID }) {
      selectedStationID = snapshot.stations.first?.id ?? ""
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
    let command = MobileCommandRecord(
      id: "command-\(UUID().uuidString)",
      stationID: target.stationID,
      kind: kind,
      risk: risk,
      status: .queued,
      title: kind.title,
      confirmationText: attention.title,
      auditReason: risk == .destructive ? "Confirmed from iPhone." : nil,
      target: target,
      actorDeviceID: "device-demo-phone",
      createdAt: now,
      expiresAt: now.addingTimeInterval(15 * 60),
      updatedAt: now
    )
    snapshot.commands.insert(command, at: 0)
    selectedStationID = target.stationID
  }

  func retry(_ command: MobileCommandRecord) {
    guard let index = snapshot.commands.firstIndex(where: { $0.id == command.id }) else {
      return
    }
    snapshot.commands[index].status = .queued
    snapshot.commands[index].updatedAt = .now
    snapshot.commands[index].expiresAt = Date().addingTimeInterval(15 * 60)
    snapshot.commands[index].receipt = nil
  }

  func cancel(_ command: MobileCommandRecord) {
    guard let index = snapshot.commands.firstIndex(where: { $0.id == command.id }) else {
      return
    }
    snapshot.commands[index].status = .cancelled
    snapshot.commands[index].updatedAt = .now
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

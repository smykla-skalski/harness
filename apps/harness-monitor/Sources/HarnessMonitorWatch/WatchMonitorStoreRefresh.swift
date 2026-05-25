import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import LocalAuthentication
import WidgetKit

extension WatchMonitorStore {
  func refresh() async {
    let generation = nextRefreshGeneration()
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
      guard let client = syncClient(for: stationID) else {
        continue
      }
      do {
        guard
          let nextSnapshot = try await fetchLatestSnapshot(
            using: client,
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

  func fetchLatestSnapshot(
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
    guard let client = syncClient(for: command.stationID) else {
      status = .unpaired
      return
    }
    do {
      let queued = try await client.queueCommand(
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
    guard let client = syncClient(for: command.stationID) else {
      status = .unpaired
      return
    }
    do {
      let receipt = try await client.cancelCommand(
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

  func applyCancellationReceipt(
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

  func preferredLiveStationID() -> String? {
    if !selectedStationID.isEmpty {
      return selectedStationID
    }
    return defaultStationID
  }

  func stationIDsForRefresh() -> [String] {
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

  func applyCachedSnapshotIfAvailable() {
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

  func applyAggregateSnapshot(
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

  func applyPairedStationPlaceholders(
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

  func authenticate(reason: String) async -> Bool {
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

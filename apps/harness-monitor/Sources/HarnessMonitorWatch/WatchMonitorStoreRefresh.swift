import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import LocalAuthentication
import WidgetKit

private let watchMonitorNoEncryptedMirrorMessage =
  "Mac has not published an encrypted mirror for this watch yet. "
  + "Keep Harness Monitor open on your Mac; Apple Watch will retry automatically."

private struct WatchRefreshState {
  var aggregateSnapshot: MobileMirrorSnapshot
  var latestGeneratedAt: Date?
  var selectedStationRefreshed = false
  var failureReason: String?
  var sawMissingMirror = false
}

extension WatchMonitorStore {
  func refresh() async {
    let generation = nextRefreshGeneration()
    guard !applyDemoRefreshIfNeeded() else { return }
    let stationIDs = stationIDsForRefresh()
    guard let preferredStationID = preferredLiveStationID() ?? stationIDs.first else {
      status = .unpaired
      return
    }

    status = .loading
    guard
      let refreshState = await performRefresh(
        stationIDs: stationIDs,
        preferredStationID: preferredStationID,
        generation: generation
      )
    else {
      return
    }

    applyRefreshState(refreshState, preferredStationID: preferredStationID)
  }

  private func applyDemoRefreshIfNeeded() -> Bool {
    guard demoModeEnabled else {
      return false
    }
    snapshot = MobileDemoFixtures.snapshot()
    status = .demo
    return true
  }

  private func performRefresh(
    stationIDs: [String],
    preferredStationID: String,
    generation: UInt64
  ) async -> WatchRefreshState? {
    var state = WatchRefreshState(aggregateSnapshot: snapshot)

    for stationID in stationIDs {
      guard let client = syncClient(for: stationID) else {
        continue
      }
      guard
        let nextState = await refreshState(
          from: state,
          client: client,
          stationID: stationID,
          preferredStationID: preferredStationID,
          generation: generation
        )
      else {
        return nil
      }
      state = nextState
    }

    guard isCurrentRefresh(generation) else {
      return nil
    }
    return state
  }

  private func refreshState(
    from refreshState: WatchRefreshState,
    client: MobileCloudMirrorSyncClient,
    stationID: String,
    preferredStationID: String,
    generation: UInt64
  ) async -> WatchRefreshState? {
    var nextState = refreshState

    do {
      guard
        let nextSnapshot = try await fetchLatestSnapshot(using: client, stationID: stationID)
      else {
        guard isCurrentRefresh(generation) else {
          return nil
        }
        nextState.failureReason = watchMonitorNoEncryptedMirrorMessage
        nextState.sawMissingMirror = true
        return nextState
      }
      guard isCurrentRefresh(generation) else {
        return nil
      }
      nextState.aggregateSnapshot = nextState.aggregateSnapshot.mergingStationSnapshot(
        nextSnapshot,
        stationID: stationID,
        defaultStationID: defaultStationID
      )
      nextState.latestGeneratedAt = max(
        nextState.latestGeneratedAt ?? nextSnapshot.generatedAt,
        nextSnapshot.generatedAt
      )
      nextState.selectedStationRefreshed =
        stationID == preferredStationID || nextState.selectedStationRefreshed
      return nextState
    } catch MobileCloudMirrorSyncError.staleSnapshot(let expiresAt) {
      guard isCurrentRefresh(generation) else {
        return nil
      }
      nextState.failureReason = "Expired \(expiresAt.formatted(.relative(presentation: .numeric)))"
      return nextState
    } catch {
      guard isCurrentRefresh(generation) else {
        return nil
      }
      nextState.failureReason = mobileMirrorReadableErrorDescription(error)
      return nextState
    }
  }

  private func applyRefreshState(
    _ refreshState: WatchRefreshState,
    preferredStationID: String
  ) {
    guard let latestGeneratedAt = refreshState.latestGeneratedAt else {
      applyCachedSnapshotIfAvailable()
      status = .stale(refreshState.failureReason ?? watchMonitorNoEncryptedMirrorMessage)
      if refreshState.sawMissingMirror {
        requestFreshPairingMaterialIfThrottleAllows()
      }
      return
    }

    applyAggregateSnapshot(refreshState.aggregateSnapshot, preferredStationID: preferredStationID)
    status =
      refreshState.selectedStationRefreshed
      ? .live(latestGeneratedAt)
      : .stale(refreshState.failureReason ?? "Selected station did not refresh")
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

  func runForegroundRefreshLoop() async {
    var backoff = MobileForegroundRefreshBackoff()
    while !Task.isCancelled {
      try? await Task.sleep(for: backoff.currentInterval)
      guard !Task.isCancelled, shouldRunForegroundRefresh else {
        continue
      }
      await refresh()
      if status.indicatesSyncFailure {
        backoff.recordFailure()
      } else {
        backoff.recordSuccess()
      }
    }
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

  private var shouldRunForegroundRefresh: Bool {
    !demoModeEnabled && !syncClientsByStationID.isEmpty
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

import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import LocalAuthentication

extension MobileMonitorStore {
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

  func queueReviewCommand(
    _ review: MobileReviewSummary,
    kind: MobileCommandKind,
    label: String? = nil,
    mergeMethod: String? = nil,
    auditReason: String? = nil
  ) async {
    await queueCommand(
      review.commandDraft(
        kind: kind,
        targetRevision: snapshot.revision,
        label: label,
        mergeMethod: mergeMethod,
        auditReason: auditReason
      )
    )
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

  func retry(_ command: MobileCommandRecord) async {
    do {
      let draft = try command.retryDraft(currentRevision: snapshot.revision)
      await queueCommand(draft)
    } catch {
      syncStatus = .commandFailed(String(describing: error))
    }
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

  func applyCancellationReceipt(
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

  func authenticate(reason: String) async -> Bool {
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

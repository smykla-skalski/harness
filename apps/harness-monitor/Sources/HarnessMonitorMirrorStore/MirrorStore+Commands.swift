import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore

extension MirrorStore {
  public func queueCommand(from attention: MobileAttentionItem) async {
    guard let kind = attention.commandKind, let target = attention.target else {
      return
    }
    let draft = MobileCommandDraft(
      kind: kind,
      confirmationText: attention.title,
      auditReason: kind == .pullRequestMerge ? profile.pullRequestMergeAuditReason : nil,
      target: target,
      payload: attention.commandPayload,
      expiresAfter: profile.commandExpiry
    )
    await queueCommand(draft)
  }

  public func queueReviewCommand(
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

  public func queueCommand(_ draft: MobileCommandDraft) async {
    let now = Date()
    let command: MobileCommandRecord
    do {
      command =
        try draft
        .makeCommand(
          id: "\(profile.commandIDPrefix)\(UUID().uuidString)",
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
      command.actorDeviceID = profile.demoActorDeviceID
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
    guard syncClient.supportsCommands else {
      syncStatus = .commandFailed("Commands are unavailable for this connection.")
      return
    }
    do {
      let submission = try await syncClient.queueCommand(
        command,
        currentRevision: snapshot.revision,
        now: now
      )
      snapshot.commands.insert(submission.command, at: 0)
      selectedStationID = command.stationID
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      let submissionStatus: MirrorSyncStatus
      switch submission.disposition {
      case .queued: submissionStatus = .commandQueued(now)
      case .completed: submissionStatus = .commandCompleted(now)
      }
      syncStatus = submissionStatus
    } catch {
      syncStatus = .commandFailed(String(describing: error))
    }
  }

  public func retry(_ command: MobileCommandRecord) async {
    do {
      let draft = try command.retryDraft(
        currentRevision: snapshot.revision,
        expiresAfter: profile.commandExpiry
      )
      await queueCommand(draft)
    } catch {
      syncStatus = .commandFailed(String(describing: error))
    }
  }

  public func cancel(_ command: MobileCommandRecord) async {
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
    guard syncClient.supportsCommands else {
      syncStatus = .commandFailed("Commands are unavailable for this connection.")
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
    await authenticator.authenticate(reason: reason)
  }
}

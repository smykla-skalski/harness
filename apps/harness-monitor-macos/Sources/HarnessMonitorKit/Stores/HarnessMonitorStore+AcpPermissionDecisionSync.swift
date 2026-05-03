import Foundation
import SwiftData

private typealias AcpDecisionSyncFailureReporter = @MainActor (String, String?, any Error) -> Void

extension HarnessMonitorStore {
  func scheduleAcpPermissionDecisionSync(
    staleDecisionIDs: Set<String>,
    protectedDecisionIDs: Set<String> = []
  ) {
    acpPermissionDecisionSyncTask?.cancel()
    guard let decisionStore = supervisorDecisionStore else {
      return
    }
    let payloads = acpPermissionPayloadsByDecisionID.values.sorted {
      if $0.rawBatch.createdAt != $1.rawBatch.createdAt {
        return $0.rawBatch.createdAt < $1.rawBatch.createdAt
      }
      return $0.decisionID < $1.decisionID
    }
    acpPermissionDecisionSyncGeneration &+= 1
    let generation = acpPermissionDecisionSyncGeneration
    let task = makeCancellationAwareAcpPermissionTask { store in
      defer {
        if store.acpPermissionDecisionSyncGeneration == generation {
          store.acpPermissionDecisionSyncTask = nil
        }
      }
      await store.performAcpPermissionDecisionSync(
        decisionStore: decisionStore,
        payloads: payloads,
        staleDecisionIDs: staleDecisionIDs,
        protectedDecisionIDs: protectedDecisionIDs,
        generation: generation
      )
    }
    acpPermissionDecisionSyncTask = task
  }

  private func performAcpPermissionDecisionSync(
    decisionStore: DecisionStore,
    payloads: [AcpPermissionDecisionPayload],
    staleDecisionIDs: Set<String>,
    protectedDecisionIDs: Set<String>,
    generation: UInt64
  ) async {
    var didPresentFailure = false
    let isCurrentGeneration = {
      generation == self.acpPermissionDecisionSyncGeneration
    }
    let reportFailure: AcpDecisionSyncFailureReporter = { operation, decisionID, error in
      self.reportAcpPermissionDecisionStoreFailure(
        operation: operation,
        decisionID: decisionID,
        error: error
      )
      if !didPresentFailure {
        self.presentFailureFeedback(
          "ACP decisions fell out of sync with the Decisions queue. Refresh the session and try again."
        )
        didPresentFailure = true
      }
    }
    guard isCurrentGeneration() else {
      return
    }
    await upsertAcpPermissionDecisionPayloads(
      payloads,
      decisionStore: decisionStore,
      isCurrentGeneration: isCurrentGeneration,
      reportFailure: reportFailure
    )
    guard !Task.isCancelled, isCurrentGeneration() else {
      return
    }
    let staleACPDecisionIDs: Set<String>
    do {
      staleACPDecisionIDs = try await staleAcpDecisionIDs(
        in: decisionStore,
        activeDecisionIDs: Set(payloads.map(\.decisionID)),
        staleDecisionIDs: staleDecisionIDs,
        protectedDecisionIDs: protectedDecisionIDs
      )
    } catch is CancellationError {
      return
    } catch {
      reportFailure("list-open", nil, error)
      return
    }
    guard !Task.isCancelled, isCurrentGeneration() else {
      return
    }
    for decisionID in staleACPDecisionIDs.sorted() {
      guard !Task.isCancelled, isCurrentGeneration() else {
        return
      }
      do {
        try await decisionStore.dismiss(id: decisionID)
      } catch is CancellationError {
        return
      } catch {
        reportFailure("dismiss", decisionID, error)
      }
    }
  }

  private func upsertAcpPermissionDecisionPayloads(
    _ payloads: [AcpPermissionDecisionPayload],
    decisionStore: DecisionStore,
    isCurrentGeneration: () -> Bool,
    reportFailure: AcpDecisionSyncFailureReporter
  ) async {
    for payload in payloads {
      guard !Task.isCancelled, isCurrentGeneration() else {
        return
      }
      do {
        try await decisionStore.upsertOpen(payload.decisionDraft)
      } catch is CancellationError {
        return
      } catch {
        reportFailure("upsert", payload.decisionID, error)
      }
    }
  }

  private func staleAcpDecisionIDs(
    in decisionStore: DecisionStore,
    activeDecisionIDs: Set<String>,
    staleDecisionIDs: Set<String>,
    protectedDecisionIDs: Set<String>
  ) async throws -> Set<String> {
    let openDecisions = try await decisionStore.openDecisions()
    return Set(
      openDecisions
        .filter { $0.ruleID == AcpPermissionDecisionPayload.ruleID }
        .map(\.id)
    )
    .subtracting(activeDecisionIDs)
    .union(staleDecisionIDs)
    .subtracting(protectedDecisionIDs)
    .subtracting(acpPermissionPendingTimeoutDecisionIDs)
    .subtracting(acpPermissionPendingShutdownDecisionIDs)
    .subtracting(Set(acpPermissionTerminalOutcomesByID.keys))
  }

  func invalidateAcpPermissionDecisionSync() {
    acpPermissionDecisionSyncTask?.cancel()
    acpPermissionDecisionSyncTask = nil
    acpPermissionDecisionSyncGeneration &+= 1
  }

  func scheduleAcpPermissionDeadlineResolution(
    for batch: AcpPermissionBatch,
    decisionID: String
  ) {
    startAcpPermissionDeadlineResolutionTask(decisionID: decisionID) { store in
      await store.performAcpPermissionDeadlineResolution(
        for: batch,
        decisionID: decisionID
      )
    }
  }

  func scheduleAcpPermissionShutdownResolution(
    for batch: AcpPermissionBatch,
    decisionID: String
  ) {
    startAcpPermissionShutdownResolutionTask(decisionID: decisionID) { store in
      await store.performAcpPermissionShutdownResolution(
        for: batch,
        decisionID: decisionID
      )
    }
  }

  private func performAcpPermissionDeadlineResolution(
    for batch: AcpPermissionBatch,
    decisionID: String
  ) async {
    guard let decisionStore = supervisorDecisionStore else {
      acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
      return
    }

    do {
      guard
        let initialDecision = try await prepareAcpPermissionDecisionForTerminalResolution(
          decisionID: decisionID,
          in: decisionStore,
          fallbackDraft: makeAcpPermissionDecisionPayload(for: batch).decisionDraft
        )
      else {
        removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
        acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
        return
      }
      try Task.checkCancellation()

      guard
        Self.isAcpPermissionDecisionUnresolved(initialDecision)
          || initialDecision.statusRaw == "dismissed"
      else {
        removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
        acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
        return
      }
      let decision = initialDecision

      let timeoutOutcome = DecisionOutcome(
        chosenActionID: nil,
        note: "client_deadline_exceeded"
      )
      try Task.checkCancellation()
      try await decisionStore.resolveTerminal(id: decisionID, outcome: timeoutOutcome)
      try Task.checkCancellation()
      if try await decisionResolvedWithTimeoutOutcome(
        decisionID: decisionID,
        expected: timeoutOutcome,
        decisionStore: decisionStore
      ) {
        try Task.checkCancellation()
        appendAcpPermissionDeadlineAudit(
          for: batch,
          decisionID: decisionID,
          agentID: decision.agentID
        )
      }
      removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
      supervisorDecisionRefreshTick &+= 1
    } catch is CancellationError {
      return
    } catch {
      reportAcpPermissionDecisionStoreFailure(
        operation: "timeout-resolve",
        decisionID: decisionID,
        error: error
      )
      removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
      acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
      scheduleAcpPermissionDecisionSync(staleDecisionIDs: [decisionID])
      return
    }

    acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
  }

  private func performAcpPermissionShutdownResolution(
    for batch: AcpPermissionBatch,
    decisionID: String
  ) async {
    guard let decisionStore = supervisorDecisionStore else {
      acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
      return
    }

    do {
      guard
        let decision = try await prepareAcpPermissionDecisionForTerminalResolution(
          decisionID: decisionID,
          in: decisionStore,
          fallbackDraft: makeAcpPermissionDecisionPayload(for: batch).decisionDraft
        )
      else {
        removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
        acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
        return
      }
      try Task.checkCancellation()
      guard
        Self.isAcpPermissionDecisionUnresolved(decision)
          || decision.statusRaw == "dismissed"
      else {
        removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
        acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
        return
      }

      let shutdownOutcome = DecisionOutcome(chosenActionID: nil, note: "daemon_shutdown")
      try Task.checkCancellation()
      try await decisionStore.resolveTerminal(id: decisionID, outcome: shutdownOutcome)
      try Task.checkCancellation()
      if try await decisionResolvedWithTimeoutOutcome(
        decisionID: decisionID,
        expected: shutdownOutcome,
        decisionStore: decisionStore
      ) {
        try Task.checkCancellation()
        appendAcpPermissionShutdownAudit(
          for: batch,
          decisionID: decisionID,
          agentID: decision.agentID
        )
      }
      removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
      supervisorDecisionRefreshTick &+= 1
    } catch is CancellationError {
      return
    } catch {
      reportAcpPermissionDecisionStoreFailure(
        operation: "shutdown-resolve",
        decisionID: decisionID,
        error: error
      )
      removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
      acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
      scheduleAcpPermissionDecisionSync(staleDecisionIDs: [decisionID])
      return
    }

    acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
  }

  func reportAcpPermissionDecisionStoreFailure(
    operation: String,
    decisionID: String?,
    error: any Error
  ) {
    let resolvedDecisionID = decisionID ?? "none"
    HarnessMonitorLogger.store.error(
      """
      ACP decision store operation failed: operation=\(operation, privacy: .public); \
      decisionID=\(resolvedDecisionID, privacy: .public); \
      error=\(error.localizedDescription, privacy: .public)
      """
    )
  }
}

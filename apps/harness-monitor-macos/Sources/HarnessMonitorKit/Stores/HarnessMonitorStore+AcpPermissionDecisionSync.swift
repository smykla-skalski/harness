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
    acpPermissionDecisionSyncTask = Task { @MainActor in
      await self.performAcpPermissionDecisionSync(
        decisionStore: decisionStore,
        payloads: payloads,
        staleDecisionIDs: staleDecisionIDs,
        protectedDecisionIDs: protectedDecisionIDs,
        generation: generation
      )
    }
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
    Task { @MainActor in
      guard let decisionStore = self.supervisorDecisionStore else {
        self.acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
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
          self.removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
          self.acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
          return
        }
        let decision: Decision
        if Self.isAcpPermissionDecisionUnresolved(initialDecision) {
          decision = initialDecision
        } else if initialDecision.statusRaw == "dismissed",
          let payload = self.acpPermissionDecisionPayload(for: decisionID)
        {
          try await decisionStore.upsertOpen(payload.decisionDraft)
          guard
            let reopenedDecision = try await waitForAcpPermissionDecision(
              id: decisionID,
              in: decisionStore
            ),
            Self.isAcpPermissionDecisionUnresolved(reopenedDecision)
          else {
            self.removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
            self.acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
            return
          }
          decision = reopenedDecision
        } else {
          self.removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
          self.acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
          return
        }
        let timeoutOutcome = DecisionOutcome(
          chosenActionID: nil,
          note: "client_deadline_exceeded"
        )
        try await decisionStore.resolveTerminal(
          id: decisionID,
          outcome: timeoutOutcome
        )
        if try await decisionResolvedWithTimeoutOutcome(
          decisionID: decisionID,
          expected: timeoutOutcome,
          decisionStore: decisionStore
        ) {
          appendAcpPermissionDeadlineAudit(
            for: batch,
            decisionID: decisionID,
            agentID: decision.agentID
          )
        }
        removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
        supervisorDecisionRefreshTick &+= 1
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
  }

  func scheduleAcpPermissionShutdownResolution(
    for batch: AcpPermissionBatch,
    decisionID: String
  ) {
    Task { @MainActor in
      guard let decisionStore = self.supervisorDecisionStore else {
        self.acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
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
          self.removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
          self.acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
          return
        }
        let shutdownOutcome = DecisionOutcome(
          chosenActionID: nil,
          note: "daemon_shutdown"
        )
        try await decisionStore.resolveTerminal(
          id: decisionID,
          outcome: shutdownOutcome
        )
        if try await decisionResolvedWithTimeoutOutcome(
          decisionID: decisionID,
          expected: shutdownOutcome,
          decisionStore: decisionStore
        ) {
          appendAcpPermissionShutdownAudit(
            for: batch,
            decisionID: decisionID,
            agentID: decision.agentID
          )
        }
        removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
        supervisorDecisionRefreshTick &+= 1
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

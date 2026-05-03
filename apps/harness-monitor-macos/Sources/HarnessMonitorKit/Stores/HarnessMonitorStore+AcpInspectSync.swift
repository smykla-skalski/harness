import Foundation

struct AcpInspectSyncEntry: Equatable, Sendable {
  let identity: AcpRuntimeIdentity
  let missingSince: Date
  var phase: AcpRuntimeInspectPhase
  var lastAttemptAt: Date?
  var retryCount: Int
  var message: String?
}

extension HarnessMonitorStore {
  public func acpRuntimeInspectStatus(for agentID: String) -> AcpRuntimeInspectStatus? {
    guard let runtimeState = acpRuntimeState(for: agentID) else {
      return nil
    }
    let entry = selectedAcpInspectSyncEntries[runtimeState.identity]
    let phase: AcpRuntimeInspectPhase =
      if let entry, entry.phase != AcpRuntimeInspectPhase.ready {
        entry.phase
      } else if runtimeState.hasInspect {
        AcpRuntimeInspectPhase.ready
      } else {
        AcpRuntimeInspectPhase.waiting
      }
    switch phase {
    case .ready:
      return AcpRuntimeInspectStatus(
        phase: .ready,
        shortLabel: "Ready",
        detail: "ACP runtime telemetry available.",
        accessibilityValue: "Runtime telemetry available"
      )
    case .waiting:
      return AcpRuntimeInspectStatus(
        phase: .waiting,
        shortLabel: "Waiting",
        detail: "Waiting for the first ACP runtime inspect snapshot.",
        accessibilityValue: "Waiting for first runtime telemetry"
      )
    case .retrying:
      let attemptCount = entry?.retryCount ?? 0
      let detail =
        if attemptCount > 1 {
          "ACP runtime telemetry is still missing. Retrying inspect (attempt \(attemptCount))."
        } else {
          "ACP runtime telemetry is still missing. Retrying inspect now."
        }
      return AcpRuntimeInspectStatus(
        phase: .retrying,
        shortLabel: "Retrying",
        detail: detail,
        accessibilityValue: "Retrying runtime telemetry"
      )
    case .stalled:
      return AcpRuntimeInspectStatus(
        phase: .stalled,
        shortLabel: "Stalled",
        detail: "ACP runtime telemetry has not arrived yet. Use Refresh if this persists.",
        accessibilityValue: "Runtime telemetry stalled"
      )
    case .unavailable:
      return AcpRuntimeInspectStatus(
        phase: .unavailable,
        shortLabel: "Unavailable",
        detail: acpInspectUnavailableMessage(for: entry),
        accessibilityValue: "Runtime telemetry unavailable"
      )
    }
  }

  func reconcileAcpInspectSyncState(
    sessionID: String,
    activeAgents: [AcpAgentSnapshot],
    response: AcpAgentInspectResponse? = nil,
    sampledAt: Date = .now,
    shouldScheduleRecovery: Bool = true
  ) {
    guard sessionID == selectedSessionID else {
      return
    }

    let activeIdentities = Set(activeAgents.map(AcpRuntimeIdentity.init(snapshot:)))
    let inspectedIdentities = Set(selectedAcpInspectAgents.map(AcpRuntimeIdentity.init(inspect:)))
    var nextEntries = selectedAcpInspectSyncEntries.filter { activeIdentities.contains($0.key) }

    for identity in inspectedIdentities {
      nextEntries.removeValue(forKey: identity)
    }

    for identity in activeIdentities.subtracting(inspectedIdentities) {
      var entry =
        nextEntries[identity]
        ?? AcpInspectSyncEntry(
          identity: identity,
          missingSince: sampledAt,
          phase: .waiting,
          lastAttemptAt: nil,
          retryCount: 0,
          message: nil
        )
      if let response {
        if response.available == false {
          entry.phase = .unavailable
          entry.message = response.issueMessage
        } else if entry.phase == .unavailable {
          entry.phase = entry.lastAttemptAt == nil ? .waiting : .stalled
          entry.message = nil
        }
      }
      nextEntries[identity] = entry
    }

    selectedAcpInspectSyncEntries = nextEntries
    guard hasRecoverableMissingAcpInspectEntries(sessionID: sessionID) else {
      cancelAcpInspectRecovery(for: sessionID)
      return
    }
    if shouldScheduleRecovery {
      restartAcpInspectRecovery(sessionID: sessionID)
    }
  }

  func cancelAcpInspectRecovery(for sessionID: String? = nil) {
    guard sessionID == nil || selectedSessionID == sessionID else {
      return
    }

    acpInspectRecoveryTask?.cancel()
    acpInspectRecoveryTask = nil
  }

  private func restartAcpInspectRecovery(sessionID: String) {
    guard selectedSessionID == sessionID else {
      cancelAcpInspectRecovery(for: sessionID)
      return
    }
    guard hasRecoverableMissingAcpInspectEntries(sessionID: sessionID) else {
      cancelAcpInspectRecovery(for: sessionID)
      return
    }

    acpInspectRecoverySequence &+= 1
    let sequence = acpInspectRecoverySequence
    acpInspectRecoveryTask?.cancel()
    let requiresGraceDelay = selectedAcpInspectSyncEntries.values.contains { entry in
      entry.phase == .waiting
    }
    let client = self.client

    acpInspectRecoveryTask = Task<Void, Never> { @MainActor [weak self] in
      guard let self else {
        return
      }
      await self.runAcpInspectRecovery(
        sequence: sequence,
        sessionID: sessionID,
        requiresGraceDelay: requiresGraceDelay,
        client: client
      )
    }
  }

  private func runAcpInspectRecovery(
    sequence: UInt64,
    sessionID: String,
    requiresGraceDelay: Bool,
    client: (any HarnessMonitorClientProtocol)?
  ) async {
    guard
      await waitForAcpInspectGraceIfNeeded(
        sequence: sequence,
        sessionID: sessionID,
        requiresGraceDelay: requiresGraceDelay
      )
    else {
      return
    }
    guard let client else { return }
    await runAcpInspectRecoveryRetries(sequence: sequence, sessionID: sessionID, client: client)
  }

  private func waitForAcpInspectGraceIfNeeded(
    sequence: UInt64,
    sessionID: String,
    requiresGraceDelay: Bool
  ) async -> Bool {
    guard requiresGraceDelay else { return true }
    do {
      try await Task.sleep(for: acpInspectGracePeriod)
    } catch {
      return false
    }
    guard isCurrentAcpInspectRecovery(sequence, sessionID: sessionID) else {
      return false
    }
    promoteAcpInspectEntriesToStalled(sessionID: sessionID, phases: [.waiting])
    return true
  }

  private func runAcpInspectRecoveryRetries(
    sequence: UInt64,
    sessionID: String,
    client: any HarnessMonitorClientProtocol
  ) async {
    for delay in acpInspectRecoveryDelays {
      guard shouldContinueAcpInspectRecovery(sequence, sessionID: sessionID) else {
        return
      }

      markAcpInspectEntriesRetrying(sessionID: sessionID)
      _ = await refreshAcpInspect(
        using: client,
        sessionID: sessionID,
        shouldScheduleRecovery: false
      )

      guard shouldContinueAcpInspectRecovery(sequence, sessionID: sessionID) else {
        return
      }

      promoteAcpInspectEntriesToStalled(sessionID: sessionID, phases: [.waiting, .retrying])
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
    }
  }

  private func shouldContinueAcpInspectRecovery(_ sequence: UInt64, sessionID: String) -> Bool {
    isCurrentAcpInspectRecovery(sequence, sessionID: sessionID)
      && hasRecoverableMissingAcpInspectEntries(sessionID: sessionID)
  }

  private func hasRecoverableMissingAcpInspectEntries(sessionID: String) -> Bool {
    guard selectedSessionID == sessionID else {
      return false
    }
    return selectedAcpInspectSyncEntries.values.contains { entry in
      entry.phase != .unavailable
    }
  }

  private func markAcpInspectEntriesRetrying(sessionID: String) {
    guard selectedSessionID == sessionID else {
      return
    }

    let attemptedAt = Date()
    var nextEntries = selectedAcpInspectSyncEntries
    for identity in nextEntries.keys.sorted(by: { $0.id < $1.id }) {
      guard var entry = nextEntries[identity], entry.phase != .unavailable else {
        continue
      }
      entry.phase = .retrying
      entry.lastAttemptAt = attemptedAt
      entry.retryCount += 1
      entry.message = nil
      nextEntries[identity] = entry
    }
    selectedAcpInspectSyncEntries = nextEntries
  }

  private func promoteAcpInspectEntriesToStalled(
    sessionID: String,
    phases: Set<AcpRuntimeInspectPhase>
  ) {
    guard selectedSessionID == sessionID else {
      return
    }

    var nextEntries = selectedAcpInspectSyncEntries
    for identity in nextEntries.keys.sorted(by: { $0.id < $1.id }) {
      guard var entry = nextEntries[identity], phases.contains(entry.phase) else {
        continue
      }
      entry.phase = .stalled
      entry.message = nil
      nextEntries[identity] = entry
    }
    selectedAcpInspectSyncEntries = nextEntries
  }

  private func isCurrentAcpInspectRecovery(_ sequence: UInt64, sessionID: String) -> Bool {
    acpInspectRecoverySequence == sequence && selectedSessionID == sessionID && !Task.isCancelled
  }

  private func acpInspectUnavailableMessage(for entry: AcpInspectSyncEntry?) -> String {
    switch hostBridgeCapabilityState(for: "acp") {
    case .excluded, .unavailable:
      return acpHostBridgeFailureMessage()
    case .ready:
      return entry?.message
        ?? "ACP runtime inspect is unavailable. Retry or restart the shared host bridge."
    }
  }
}

import Foundation
import SwiftData

typealias AcpPermissionTaskMapKeyPath =
  ReferenceWritableKeyPath<HarnessMonitorStore, [String: Task<Void, Never>]>
typealias AcpPermissionTaskTokenMapKeyPath =
  ReferenceWritableKeyPath<HarnessMonitorStore, [String: UInt64]>

extension HarnessMonitorStore {
  func makeCancellationAwareAcpPermissionTask(
    _ operation: @escaping @MainActor (HarnessMonitorStore) async -> Void
  ) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      // Give immediate invalidation/reset paths one turn to cancel before this
      // task touches the decision store or writes audit rows.
      await Task.yield()
      guard !Task.isCancelled, let self else {
        return
      }
      await operation(self)
    }
  }

  private func startAcpPermissionResolutionTask(
    decisionID: String,
    taskKeyPath: AcpPermissionTaskMapKeyPath,
    tokenKeyPath: AcpPermissionTaskTokenMapKeyPath,
    operation: @escaping @MainActor (HarnessMonitorStore) async -> Void
  ) {
    cancelAcpPermissionResolutionTask(
      decisionID: decisionID,
      taskKeyPath: taskKeyPath,
      tokenKeyPath: tokenKeyPath
    )
    let token = nextAcpPermissionResolutionTaskToken(
      decisionID: decisionID,
      tokenKeyPath: tokenKeyPath
    )
    let task = makeCancellationAwareAcpPermissionTask { store in
      defer {
        store.finishAcpPermissionResolutionTask(
          decisionID: decisionID,
          taskKeyPath: taskKeyPath,
          tokenKeyPath: tokenKeyPath,
          token: token
        )
      }
      await operation(store)
    }
    self[keyPath: taskKeyPath][decisionID] = task
  }

  func startAcpPermissionDeadlineResolutionTask(
    decisionID: String,
    operation: @escaping @MainActor (HarnessMonitorStore) async -> Void
  ) {
    startAcpPermissionResolutionTask(
      decisionID: decisionID,
      taskKeyPath: \.acpPermissionDeadlineResolutionTasks,
      tokenKeyPath: \.acpDeadlineResolutionTokens,
      operation: operation
    )
  }

  func startAcpPermissionShutdownResolutionTask(
    decisionID: String,
    operation: @escaping @MainActor (HarnessMonitorStore) async -> Void
  ) {
    startAcpPermissionResolutionTask(
      decisionID: decisionID,
      taskKeyPath: \.acpPermissionShutdownResolutionTasks,
      tokenKeyPath: \.acpShutdownResolutionTokens,
      operation: operation
    )
  }

  func cancelAcpPermissionDeadlineResolutionTask(for decisionID: String) {
    cancelAcpPermissionResolutionTask(
      decisionID: decisionID,
      taskKeyPath: \.acpPermissionDeadlineResolutionTasks,
      tokenKeyPath: \.acpDeadlineResolutionTokens
    )
  }

  func cancelAcpPermissionShutdownResolutionTask(for decisionID: String) {
    cancelAcpPermissionResolutionTask(
      decisionID: decisionID,
      taskKeyPath: \.acpPermissionShutdownResolutionTasks,
      tokenKeyPath: \.acpShutdownResolutionTokens
    )
  }

  func cancelAcpPermissionTerminalResolutionTasks(for decisionID: String) {
    cancelAcpPermissionDeadlineResolutionTask(for: decisionID)
    cancelAcpPermissionShutdownResolutionTask(for: decisionID)
  }

  func cancelAllAcpPermissionResolutionTasks() {
    cancelAcpPermissionResolutionTasks(
      taskKeyPath: \.acpPermissionDeadlineResolutionTasks,
      tokenKeyPath: \.acpDeadlineResolutionTokens
    )
    cancelAcpPermissionResolutionTasks(
      taskKeyPath: \.acpPermissionShutdownResolutionTasks,
      tokenKeyPath: \.acpShutdownResolutionTokens
    )
  }

  func stopAcpPermissionDecisionProcessing() {
    cancelAllAcpPermissionResolutionTasks()
    invalidateAcpPermissionDecisionSync()
    acpPermissionPendingTimeoutDecisionIDs.removeAll()
    acpPermissionPendingShutdownDecisionIDs.removeAll()
    acpPermissionTerminalOutcomesByID.removeAll()
  }

  func appendAcpPermissionShutdownAudit(
    for batch: AcpPermissionBatch,
    decisionID: String,
    agentID: String?
  ) {
    guard let container = modelContext?.container else {
      return
    }
    let context = ModelContext(container)
    context.autosaveEnabled = false
    context.insert(
      SupervisorEvent(
        id: UUID().uuidString,
        tickID: "acp-shutdown-\(batch.batchId)",
        kind: "acp_permission_daemon_shutdown",
        ruleID: AcpPermissionDecisionPayload.ruleID,
        severity: .warn,
        payloadJSON: encodeAcpPermissionShutdownAuditPayload(
          decisionID: decisionID,
          batchID: batch.batchId,
          sessionID: batch.sessionId,
          agentID: agentID,
          managedAgentID: batch.acpId
        )
      )
    )
    try? context.save()
  }

  func appendAcpPermissionDeadlineAudit(
    for batch: AcpPermissionBatch,
    decisionID: String,
    agentID: String?
  ) {
    guard let container = modelContext?.container else {
      return
    }
    let context = ModelContext(container)
    context.autosaveEnabled = false
    do {
      guard try !hasAcpPermissionDeadlineAudit(batchID: batch.batchId, in: context) else {
        return
      }
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.audit_query_failed error=\(String(describing: error))"
      )
      return
    }
    context.insert(
      SupervisorEvent(
        id: UUID().uuidString,
        tickID: "acp-timeout-\(batch.batchId)",
        kind: "acp_permission_deadline_expired",
        ruleID: AcpPermissionDecisionPayload.ruleID,
        severity: .warn,
        payloadJSON: encodeAcpPermissionDeadlineAuditPayload(
          decisionID: decisionID,
          batchID: batch.batchId,
          sessionID: batch.sessionId,
          agentID: agentID,
          managedAgentID: batch.acpId
        )
      )
    )
    do {
      try context.save()
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.audit_append_failed error=\(String(describing: error))"
      )
    }
  }

  func encodeAcpPermissionDeadlineAuditPayload(
    decisionID: String,
    batchID: String,
    sessionID: String,
    agentID: String?,
    managedAgentID: String
  ) -> String {
    let payload = AcpPermissionDeadlineAuditPayload(
      decisionID: decisionID,
      batchID: batchID,
      sessionID: sessionID,
      agentID: agentID,
      managedAgentID: managedAgentID,
      reason: "client_deadline_exceeded"
    )
    guard
      let data = try? acpPermissionAuditEncoder.encode(payload),
      let json = String(data: data, encoding: .utf8)
    else {
      return #"{"reason":"client_deadline_exceeded"}"#
    }
    return json
  }

  func encodeAcpPermissionShutdownAuditPayload(
    decisionID: String,
    batchID: String,
    sessionID: String,
    agentID: String?,
    managedAgentID: String
  ) -> String {
    let payload = AcpPermissionShutdownAuditPayload(
      decisionID: decisionID,
      batchID: batchID,
      sessionID: sessionID,
      agentID: agentID,
      managedAgentID: managedAgentID,
      reason: "daemon_shutdown",
      uiAnnotation: "removed_after_daemon_shutdown"
    )
    guard
      let data = try? acpPermissionAuditEncoder.encode(payload),
      let json = String(data: data, encoding: .utf8)
    else {
      return #"{"reason":"daemon_shutdown","uiAnnotation":"removed_after_daemon_shutdown"}"#
    }
    return json
  }

  func terminalOutcome(for reason: AcpPermissionBatchRemovalReason) -> DecisionOutcome {
    switch reason {
    case .timeout:
      return DecisionOutcome(chosenActionID: nil, note: "client_deadline_exceeded")
    case .shutdown:
      return DecisionOutcome(chosenActionID: nil, note: "daemon_shutdown")
    case .resolved:
      return DecisionOutcome(chosenActionID: nil, note: nil)
    }
  }

  func waitForAcpPermissionDecision(
    id decisionID: String,
    in decisionStore: DecisionStore
  ) async throws -> Decision? {
    let attempts = 20
    let poll = Duration.milliseconds(50)
    for index in 0...attempts {
      try Task.checkCancellation()
      if let decision = try await decisionStore.decision(id: decisionID) {
        return decision
      }
      guard index < attempts else {
        break
      }
      try await Task.sleep(for: poll)
    }
    return nil
  }

  func prepareAcpPermissionDecisionForTerminalResolution(
    decisionID: String,
    in decisionStore: DecisionStore,
    fallbackDraft: DecisionDraft? = nil
  ) async throws -> Decision? {
    if let payload = acpPermissionDecisionPayload(for: decisionID) {
      try await decisionStore.upsertOpen(payload.decisionDraft)
    } else if let fallbackDraft {
      try await decisionStore.upsertOpen(fallbackDraft)
    }
    return try await waitForAcpPermissionDecision(id: decisionID, in: decisionStore)
  }

  func decisionResolvedWithTimeoutOutcome(
    decisionID: String,
    expected: DecisionOutcome,
    decisionStore: DecisionStore
  ) async throws -> Bool {
    guard let decision = try await decisionStore.decision(id: decisionID),
      decision.statusRaw == "resolved",
      let resolutionJSON = decision.resolutionJSON,
      let data = resolutionJSON.data(using: .utf8),
      let outcome = try? acpPermissionOutcomeDecoder.decode(DecisionOutcome.self, from: data)
    else {
      return false
    }
    return outcome == expected
  }

  static func isAcpPermissionDecisionUnresolved(_ decision: Decision) -> Bool {
    decision.statusRaw == "open" || decision.statusRaw == "snoozed"
  }

  func hasAcpPermissionDeadlineAudit(
    batchID: String,
    in context: ModelContext
  ) throws -> Bool {
    let tickID = "acp-timeout-\(batchID)"
    var descriptor = FetchDescriptor<SupervisorEvent>(
      predicate: #Predicate<SupervisorEvent> { $0.tickID == tickID }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).isEmpty == false
  }

  private func nextAcpPermissionResolutionTaskToken(
    decisionID: String,
    tokenKeyPath: AcpPermissionTaskTokenMapKeyPath
  ) -> UInt64 {
    let nextToken = (self[keyPath: tokenKeyPath][decisionID] ?? 0) &+ 1
    self[keyPath: tokenKeyPath][decisionID] = nextToken
    return nextToken
  }

  private func finishAcpPermissionResolutionTask(
    decisionID: String,
    taskKeyPath: AcpPermissionTaskMapKeyPath,
    tokenKeyPath: AcpPermissionTaskTokenMapKeyPath,
    token: UInt64
  ) {
    guard self[keyPath: tokenKeyPath][decisionID] == token else {
      return
    }
    self[keyPath: taskKeyPath].removeValue(forKey: decisionID)
    self[keyPath: tokenKeyPath].removeValue(forKey: decisionID)
  }

  private func cancelAcpPermissionResolutionTask(
    decisionID: String,
    taskKeyPath: AcpPermissionTaskMapKeyPath,
    tokenKeyPath: AcpPermissionTaskTokenMapKeyPath
  ) {
    let task = self[keyPath: taskKeyPath].removeValue(forKey: decisionID)
    self[keyPath: tokenKeyPath].removeValue(forKey: decisionID)
    task?.cancel()
  }

  private func cancelAcpPermissionResolutionTasks(
    taskKeyPath: AcpPermissionTaskMapKeyPath,
    tokenKeyPath: AcpPermissionTaskTokenMapKeyPath
  ) {
    let tasks = Array(self[keyPath: taskKeyPath].values)
    self[keyPath: taskKeyPath].removeAll()
    self[keyPath: tokenKeyPath].removeAll()
    for task in tasks { task.cancel() }
  }
}

private struct AcpPermissionDeadlineAuditPayload: Encodable {
  let decisionID: String
  let batchID: String
  let sessionID: String
  let agentID: String?
  let managedAgentID: String
  let reason: String
}

private struct AcpPermissionShutdownAuditPayload: Encodable {
  let decisionID: String
  let batchID: String
  let sessionID: String
  let agentID: String?
  let managedAgentID: String
  let reason: String
  let uiAnnotation: String
}

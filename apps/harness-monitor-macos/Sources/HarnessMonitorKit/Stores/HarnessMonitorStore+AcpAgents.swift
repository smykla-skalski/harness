import Foundation
import SwiftData

extension HarnessMonitorStore {
  private struct AcpRetryContext {
    let firstFailureRecordedAt: Date
    let recordsIncidentRetry: Bool
  }

  enum AcpStartRecoveryOutcome {
    case notAttempted
    case succeeded(AcpAgentSnapshot)
    case failed
  }

  /// Pending ACP queue for the selected session.
  ///
  /// UI-0 contract: this array stays oldest-first by daemon `createdAt`, but selection/presentation
  /// is sticky to the batch the operator is already handling. Future Decisions-window rows may
  /// render the same queue differently, but they must preserve these ordering semantics.
  public var pendingAcpPermissionBatches: [AcpPermissionBatch] {
    let selectedBatches = selectedAcpAgents.flatMap(\.pendingPermissionBatches)
    return sortedAcpPermissionBatches(
      mergedPermissionBatches(
        primary: selectedBatches,
        secondary: standaloneAcpPermissionBatches,
        preferSecondary: false
      )
    )
  }

  public func fetchAcpAgentDescriptors() async -> [AcpAgentDescriptor] {
    guard let client else {
      return Array(acpAgentDescriptorsByID.values)
    }
    let descriptors =
      (try? await client.acpAgentDescriptors()) ?? Array(acpAgentDescriptorsByID.values)
    acpAgentDescriptorsByID = Dictionary(
      uniqueKeysWithValues: descriptors.map { ($0.id, $0) }
    )
    return descriptors
  }

  public func fetchRuntimeProbeResults() async -> AcpRuntimeProbeResponse? {
    guard let client else { return nil }
    return try? await client.runtimeProbeResults()
  }

  @discardableResult
  public func startAcpAgent(
    agentID: String,
    role: SessionRole = .worker,
    fallbackRole: SessionRole? = nil,
    capabilities: [String] = [],
    name: String?,
    prompt: String?,
    projectDir: String? = nil,
    persona: String? = nil,
    recordPermissions: Bool = false,
    sessionID: String? = nil
  ) async -> AcpAgentSnapshot? {
    let actionName = "Agent started"
    let explicitSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let action =
      if let explicitSessionID, !explicitSessionID.isEmpty {
        prepareSessionAction(named: actionName, sessionID: explicitSessionID)
      } else {
        prepareSelectedSessionAction(named: actionName)
      }
    guard let action else { return nil }
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProjectDir = projectDir?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPersona = persona?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedCapabilities =
      capabilities
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let request = AcpAgentStartRequest(
      agent: agentID,
      role: role,
      fallbackRole: fallbackRole,
      capabilities: normalizedCapabilities,
      name: trimmedName?.isEmpty == false ? trimmedName : nil,
      prompt: trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil,
      projectDir: trimmedProjectDir?.isEmpty == false ? trimmedProjectDir : nil,
      persona: trimmedPersona?.isEmpty == false ? trimmedPersona : nil,
      recordPermissions: recordPermissions
    )

    do {
      let measuredSnapshot = try await measureAcpAgentStart(
        using: action.client,
        sessionID: action.sessionID,
        request: request
      )
      guard let snapshot = acpAgentSnapshot(from: measuredSnapshot.value) else {
        presentFailureFeedback("Agent controller returned an unexpected response.")
        return nil
      }
      applyAcpAgentStartSuccess(snapshot, actionName: actionName)
      return snapshot
    } catch let apiError as HarnessMonitorAPIError {
      let firstFailureRecordedAt = Date.now
      switch await recoverAcpStartAfterBridgeFailure(
        using: action.client,
        sessionID: action.sessionID,
        request: request,
        error: apiError,
        firstFailureRecordedAt: firstFailureRecordedAt
      ) {
      case .succeeded(let snapshot):
        applyAcpAgentStartSuccess(snapshot, actionName: actionName)
        return snapshot
      case .failed:
        return nil
      case .notAttempted:
        break
      }
      if case .server(let code, _) = apiError, code == 501 || code == 503 {
        markHostBridgeIssue(
          for: "acp",
          statusCode: code,
          recordedAt: firstFailureRecordedAt
        )
        presentFailureFeedback(acpHostBridgeFailureMessage())
        return nil
      }
      presentFailureFeedback(apiError.localizedDescription)
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  private func applyAcpAgentStartSuccess(
    _ snapshot: AcpAgentSnapshot,
    actionName: String
  ) {
    recordRequestSuccess()
    clearHostBridgeIssue(for: "acp")
    switch applyAcpAgent(snapshot) {
    case .applied:
      presentSuccessFeedback(actionName)
    case .droppedSessionMismatch:
      presentSuccessFeedback(
        Self.acpAgentStartedInOtherSessionMessage(actionName: actionName)
      )
    }
  }

  static func acpAgentStartedInOtherSessionMessage(actionName: String) -> String {
    "\(actionName) in another session. Reselect that session to view it."
  }

  private func measureAcpAgentStart(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    request: AcpAgentStartRequest
  ) async throws -> MeasuredOperation<ManagedAgentSnapshot> {
    try await Self.measureOperation {
      try await client.startManagedAcpAgent(sessionID: sessionID, request: request)
    }
  }

  private func acpAgentSnapshot(from snapshot: ManagedAgentSnapshot) -> AcpAgentSnapshot? {
    guard case .acp(let acpSnapshot) = snapshot else {
      return nil
    }
    return acpSnapshot
  }

  private func recoverAcpStartAfterBridgeFailure(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    request: AcpAgentStartRequest,
    error: HarnessMonitorAPIError,
    firstFailureRecordedAt: Date
  ) async -> AcpStartRecoveryOutcome {
    guard case .server(let code, _) = error, code == 501 || code == 503 else {
      return .notAttempted
    }
    guard daemonStatus?.manifest?.sandboxed == true else {
      return .notAttempted
    }

    let currentHostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    let retryContext = AcpRetryContext(
      firstFailureRecordedAt: firstFailureRecordedAt,
      recordsIncidentRetry: code == 503
    )

    if let recovery = await retryAcpStartIfRunningHostBridge(
      using: client,
      sessionID: sessionID,
      request: request,
      hostBridge: currentHostBridge,
      retryContext: retryContext
    ) {
      return recovery
    }

    await refreshDaemonStatus()
    reconcileHostBridgeIssueFromManifest(for: "acp")

    let refreshedHostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    guard daemonStatus?.manifest?.sandboxed == true else {
      return .notAttempted
    }
    guard
      let recovery = await retryAcpStartIfRunningHostBridge(
        using: client,
        sessionID: sessionID,
        request: request,
        hostBridge: refreshedHostBridge,
        retryContext: retryContext
      )
    else {
      return .notAttempted
    }
    return recovery
  }

  private func retryAcpStartIfRunningHostBridge(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    request: AcpAgentStartRequest,
    hostBridge: HostBridgeManifest,
    retryContext: AcpRetryContext
  ) async -> AcpStartRecoveryOutcome? {
    guard hostBridge.running else {
      return nil
    }
    var effectiveClient: any HarnessMonitorClientProtocol = client
    if hostBridge.capabilities["acp"]?.healthy != true {
      switch await mutateHostBridgeCapability(
        using: client,
        capability: "acp",
        enabled: true,
        force: false,
        announceFeedback: false
      ) {
      case .success:
        effectiveClient = self.client ?? client
      case .requiresForce(let message):
        presentFailureFeedback(message)
        return .failed
      case .failed:
        return .failed
      }
    }
    if retryContext.recordsIncidentRetry {
      noteAcpBridgeRetryAttempt(
        for: "acp",
        recordedAt: retryContext.firstFailureRecordedAt
      )
    }

    do {
      let measuredSnapshot = try await measureAcpAgentStart(
        using: effectiveClient,
        sessionID: sessionID,
        request: request
      )
      guard let snapshot = acpAgentSnapshot(from: measuredSnapshot.value) else {
        presentFailureFeedback("Agent controller returned an unexpected response.")
        return .failed
      }
      return .succeeded(snapshot)
    } catch let retryError as HarnessMonitorAPIError {
      if case .server(let retryCode, _) = retryError, retryCode == 501 || retryCode == 503 {
        markHostBridgeIssue(
          for: "acp",
          statusCode: retryCode,
          recordedAt: retryContext.firstFailureRecordedAt
        )
        presentFailureFeedback(acpHostBridgeFailureMessage())
        return .failed
      }
      presentFailureFeedback(retryError.localizedDescription)
      return .failed
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return .failed
    }
  }

}

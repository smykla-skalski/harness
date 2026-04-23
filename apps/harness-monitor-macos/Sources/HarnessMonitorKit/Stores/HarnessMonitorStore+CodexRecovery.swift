import Foundation

extension HarnessMonitorStore {
  enum CodexStartRecoveryOutcome {
    case notAttempted
    case succeeded(CodexRunSnapshot)
    case failed
  }

  func applyCodexRunStartSuccess(_ run: CodexRunSnapshot) {
    recordRequestSuccess()
    clearHostBridgeIssue(for: "codex")
    applyCodexRun(run, selectingRun: true)
    presentSuccessFeedback("Codex run started")
  }

  func recoverCodexStartAfterTransientBridgeFailure(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    request: CodexRunRequest,
    error: HarnessMonitorAPIError
  ) async -> CodexStartRecoveryOutcome {
    guard case .server(let code, _) = error, code == 503 else {
      return .notAttempted
    }
    guard daemonStatus?.manifest?.sandboxed == true else {
      return .notAttempted
    }

    await refreshDaemonStatus()
    reconcileHostBridgeIssueFromManifest(for: "codex")

    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    guard hostBridge.running, hostBridge.capabilities["codex"]?.healthy == true else {
      markHostBridgeIssue(for: "codex", statusCode: code)
      return .notAttempted
    }

    do {
      let measuredRun = try await measureCodexRunStart(
        using: client,
        sessionID: sessionID,
        request: request
      )
      applyCodexRunStartSuccess(measuredRun.value)
      return .succeeded(measuredRun.value)
    } catch let retryError as HarnessMonitorAPIError {
      if case .server(let retryCode, _) = retryError, retryCode == 501 || retryCode == 503 {
        markHostBridgeIssue(for: "codex", statusCode: retryCode)
      }
      presentFailureFeedback(retryError.localizedDescription)
      return .failed
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return .failed
    }
  }

  func reconcileHostBridgeIssueFromManifest(for capability: String) {
    guard !forcedHostBridgeCapabilities.contains(capability) else {
      return
    }
    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    guard daemonStatus?.manifest?.sandboxed == true else {
      clearHostBridgeIssue(for: capability)
      return
    }
    guard hostBridge.running else {
      hostBridgeCapabilityIssues[capability] = .unavailable
      return
    }
    guard let capabilityState = hostBridge.capabilities[capability] else {
      hostBridgeCapabilityIssues[capability] = .excluded
      return
    }
    if capabilityState.healthy {
      clearHostBridgeIssue(for: capability)
    } else {
      hostBridgeCapabilityIssues[capability] = .unavailable
    }
  }
}

import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func configureCodexStartError(_ error: (any Error)?) {
    lock.withLock {
      codexStartError = error
      queuedCodexStartErrors = []
    }
  }

  func configureCodexStartErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedCodexStartErrors = errors
      codexStartError = nil
    }
  }

  func configureAcpStartError(_ error: (any Error)?) {
    lock.withLock {
      acpStartError = error
      queuedAcpStartErrors = []
    }
  }

  func configureAcpInspectError(_ error: (any Error)?) {
    lock.withLock { acpInspectError = error }
  }

  func configureAcpTranscriptResponse(
    _ response: AcpTranscriptResponse,
    for sessionID: String
  ) {
    lock.withLock {
      acpTranscriptResponsesBySessionID[sessionID] = response
    }
  }

  func configureCodexTranscriptResponse(
    _ response: CodexTranscriptResponse,
    for sessionID: String
  ) {
    lock.withLock {
      codexTranscriptResponsesBySessionID[sessionID] = response
    }
  }

  func configureAcpTranscriptDelay(
    _ delay: Duration?,
    for sessionID: String
  ) {
    lock.withLock {
      acpTranscriptDelaysBySessionID[sessionID] = delay
    }
  }

  func configureAcpTranscriptError(
    _ error: (any Error)?,
    for sessionID: String
  ) {
    lock.withLock {
      if let error {
        acpTranscriptErrorsBySessionID[sessionID] = error
      } else {
        acpTranscriptErrorsBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configureAcpStartErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedAcpStartErrors = errors
      acpStartError = nil
    }
  }

  func configureAgentTuiStartError(_ error: (any Error)?) {
    lock.withLock { agentTuiStartError = error }
  }

  func configureHostBridgeReconfigureError(_ error: (any Error)?) {
    lock.withLock { hostBridgeReconfigureError = error }
  }

  func configureHostBridgeStatusReport(_ report: BridgeStatusReport) {
    lock.withLock { hostBridgeStatusReport = report }
  }

  func configuredCodexStartError() -> (any Error)? {
    lock.withLock { codexStartError }
  }

  func dequeueConfiguredCodexStartError() -> (any Error)? {
    lock.withLock {
      guard let error = queuedCodexStartErrors.first else {
        return codexStartError
      }
      queuedCodexStartErrors.removeFirst()
      return error
    }
  }

  func configuredAgentTuiStartError() -> (any Error)? {
    lock.withLock { agentTuiStartError }
  }

  func dequeueConfiguredAcpStartError() -> (any Error)? {
    lock.withLock {
      guard let error = queuedAcpStartErrors.first else {
        return acpStartError
      }
      queuedAcpStartErrors.removeFirst()
      return error
    }
  }

  func configuredAcpInspectError() -> (any Error)? {
    lock.withLock { acpInspectError }
  }

  func configuredHostBridgeReconfigureError() -> (any Error)? {
    lock.withLock { hostBridgeReconfigureError }
  }

  func configuredHostBridgeStatusReport() -> BridgeStatusReport {
    lock.withLock { hostBridgeStatusReport }
  }

  func configuredHealthDelay() -> Duration? { lock.withLock { healthDelay } }
  func configuredTransportLatencyMs() -> Int? { lock.withLock { transportLatencyMsValue } }
  func configuredTransportLatencyError() -> (any Error)? {
    lock.withLock { transportLatencyError }
  }
  func configuredDiagnosticsDelay() -> Duration? { lock.withLock { diagnosticsDelay } }
  func configuredProjectsDelay() -> Duration? { lock.withLock { projectsDelay } }
  func configuredSessionsDelay() -> Duration? { lock.withLock { sessionsDelay } }

}

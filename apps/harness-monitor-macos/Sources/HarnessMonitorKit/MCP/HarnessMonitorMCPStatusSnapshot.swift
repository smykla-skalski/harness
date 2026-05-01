import Foundation

public struct HarnessMonitorMCPStatusSnapshot: Equatable, Sendable {
  public enum Tone: String, Equatable, Sendable {
    case secondary
    case info
    case success
    case caution
  }

  public let runtimeState: HarnessMonitorMCPRuntimeState
  public let recoveryStatus: HarnessMonitorMCPRecoveryStatus?

  public init(
    runtimeState: HarnessMonitorMCPRuntimeState,
    recoveryStatus: HarnessMonitorMCPRecoveryStatus?
  ) {
    self.runtimeState = runtimeState
    self.recoveryStatus = recoveryStatus
  }

  public var socketPath: String? {
    runtimeState.socketPath
  }

  public var failureReason: String? {
    runtimeState.reason
  }

  public var tone: Tone {
    switch runtimeState {
    case .disabled:
      .secondary
    case .starting:
      .info
    case .healthy:
      .success
    case .degraded:
      .caution
    }
  }

  public var symbolName: String {
    switch runtimeState {
    case .disabled:
      "slash.circle"
    case .starting:
      "hourglass.circle"
    case .healthy:
      "checkmark.circle.fill"
    case .degraded:
      isRecovering ? "arrow.clockwise.circle.fill" : "exclamationmark.triangle.fill"
    }
  }

  public var title: String {
    switch runtimeState {
    case .disabled:
      "Registry Host Disabled"
    case .starting:
      "Registry Host Starting"
    case .healthy:
      "Registry Host Ready"
    case .degraded:
      isRecovering ? "Registry Host Degraded - Recovering" : "Registry Host Degraded"
    }
  }

  public var toolbarLabel: String {
    switch runtimeState {
    case .disabled:
      "Host Off"
    case .starting:
      "Host Starting"
    case .healthy:
      "Host Ready"
    case .degraded:
      isRecovering ? "Host Recovering" : "Host Degraded"
    }
  }

  public var detail: String {
    switch runtimeState {
    case .disabled:
      return "The in-app MCP accessibility registry host is disabled."
    case .starting(let socketPath):
      if let socketPath {
        return
          "Starting the in-app MCP accessibility registry host at \(socketPath). "
          + hostScopeClarification
      }
      return "Starting the in-app MCP accessibility registry host. \(hostScopeClarification)"
    case .healthy(let socketPath):
      return
        "The in-app MCP accessibility registry host is responding at \(socketPath). "
        + hostScopeClarification
    case .degraded(_, let reason):
      let summary = recoverySummary
      let guidance = recoveryGuidance
      if let summary {
        return "The MCP registry host is unavailable: \(reason). \(summary) \(guidance)"
      }
      return "The MCP registry host is unavailable: \(reason). \(guidance)"
    }
  }

  public var recoverySummary: String? {
    guard let recoveryStatus else {
      return nil
    }
    if let nextRetryDelay = recoveryStatus.nextRetryDelay {
      let nextAttempt = min(
        recoveryStatus.maximumRetryCount,
        recoveryStatus.completedRetryCount + 1
      )
      return
        "Recovery continues in the background. Retry \(nextAttempt) of "
        + "\(recoveryStatus.maximumRetryCount) is scheduled"
        + " \(formattedDelay(nextRetryDelay))."
    }
    guard recoveryStatus.completedRetryCount > 0 else {
      return nil
    }
    return
      "Automatic recovery paused after \(recoveryStatus.completedRetryCount) "
      + "attempts."
  }

  public var shouldShowChromeBanner: Bool {
    if case .degraded = runtimeState {
      return true
    }
    return false
  }

  public var accessibilityLabel: String {
    "MCP accessibility registry host status"
  }

  public var accessibilityValue: String {
    detail
  }

  public var failureFeedbackMessage: String? {
    guard case .degraded(_, let reason) = runtimeState else {
      return nil
    }
    if let recoverySummary {
      return "MCP registry host degraded: \(reason). \(recoverySummary) \(recoveryGuidance)"
    }
    return "MCP registry host degraded: \(reason). \(recoveryGuidance)"
  }

  private var isRecovering: Bool {
    guard case .degraded = runtimeState else {
      return false
    }
    return recoveryStatus?.nextRetryDelay != nil
  }

  private var recoveryGuidance: String {
    if isRecovering {
      return "You can keep working while the registry retries in the background."
    }
    return "Correct the problem, then open Preferences > MCP to re-enable the registry host."
  }

  private var hostScopeClarification: String {
    "This status covers the in-app registry host. MCP clients still validate helper-backed accessibility actions when requests need them."
  }

  private func formattedDelay(_ delay: Duration) -> String {
    let seconds = max(0, delay.components.seconds)
    let suffix = seconds == 1 ? "second" : "seconds"
    return "in \(seconds) \(suffix)"
  }
}

import Foundation

public struct AcpBridgeHTTPIncident: Equatable, Sendable {
  public let firstDetectedAt: Date
  public let retryCount: Int

  public init(firstDetectedAt: Date, retryCount: Int) {
    self.firstDetectedAt = firstDetectedAt
    self.retryCount = retryCount
  }

  func incrementingRetryCount() -> AcpBridgeHTTPIncident {
    AcpBridgeHTTPIncident(
      firstDetectedAt: firstDetectedAt,
      retryCount: retryCount + 1
    )
  }
}

public struct AcpBridgeBannerState: Equatable, Sendable {
  public let firstDetectedAt: Date
  public let retryCount: Int
  public let daemonLogAvailable: Bool

  @MainActor private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  public static let blastRadiusText =
    "ACP sessions cannot make tool calls; existing TUI agents unaffected"

  public init(
    firstDetectedAt: Date,
    retryCount: Int,
    daemonLogAvailable: Bool
  ) {
    self.firstDetectedAt = firstDetectedAt
    self.retryCount = retryCount
    self.daemonLogAvailable = daemonLogAvailable
  }

  @MainActor public var factText: String {
    "Daemon process not responding to ACP HTTP since "
      + "\(Self.timeFormatter.string(from: firstDetectedAt)), \(retrySummary)"
  }

  @MainActor private var retrySummary: String {
    retryCount == 1 ? "1 retry" : "\(retryCount) retries"
  }
}

extension HarnessMonitorStore {
  public var acpBridgeBannerState: AcpBridgeBannerState? {
    guard let incident = acpBridgeHTTPIncident, shouldPresentAcpBridgeBanner else {
      return nil
    }
    return AcpBridgeBannerState(
      firstDetectedAt: incident.firstDetectedAt,
      retryCount: incident.retryCount,
      daemonLogAvailable: daemonLogURL() != nil
    )
  }

  public func hostBridgeCapabilityState(for capability: String) -> HostBridgeCapabilityState {
    guard daemonStatus?.manifest?.sandboxed == true else {
      return .ready
    }

    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    if let issue = hostBridgeCapabilityIssues[capability] {
      switch issue {
      case .unavailable:
        return .unavailable
      case .excluded:
        guard hostBridge.running else {
          return .unavailable
        }
        if let capabilityState = hostBridge.capabilities[capability] {
          return capabilityState.healthy ? .ready : .unavailable
        }
        return .excluded
      }
    }

    guard hostBridge.running else {
      return .unavailable
    }
    guard let capabilityState = hostBridge.capabilities[capability] else {
      return .excluded
    }
    return capabilityState.healthy ? .ready : .unavailable
  }

  public static func parseForcedBridgeIssues(
    from environment: [String: String]
  ) -> [String: HostBridgeCapabilityIssue] {
    guard
      let rawValue = environment["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else {
      return [:]
    }

    var issues: [String: HostBridgeCapabilityIssue] = [:]
    for capability in rawValue.split(separator: ",") {
      let trimmedCapability = capability.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedCapability.isEmpty else {
        continue
      }
      issues[trimmedCapability] = .excluded
    }
    return issues
  }

  public func hostBridgeStartCommand(for capability: String) -> String {
    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    if hostBridge.running {
      return "harness bridge reconfigure --enable \(capability)"
    }
    return "harness bridge start"
  }

  public func clearHostBridgeIssue(for capability: String) {
    if forcedHostBridgeCapabilities.contains(capability) {
      return
    }
    hostBridgeCapabilityIssues.removeValue(forKey: capability)
    if capability == "codex" {
      acpBridgeHTTPIncident = nil
    }
  }

  func clearTransientHostBridgeIssues() {
    hostBridgeCapabilityIssues = hostBridgeCapabilityIssues.filter {
      forcedHostBridgeCapabilities.contains($0.key)
    }
    reconcileAcpBridgeIncidentVisibility()
  }

  public func markHostBridgeIssue(
    for capability: String,
    statusCode: Int,
    recordedAt: Date = .now
  ) {
    switch statusCode {
    case 501:
      let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
      if hostBridge.running && hostBridge.capabilities[capability] == nil {
        hostBridgeCapabilityIssues[capability] = .excluded
      } else {
        hostBridgeCapabilityIssues[capability] = .unavailable
      }
    case 503:
      hostBridgeCapabilityIssues[capability] = .unavailable
    default:
      break
    }
    recordAcpBridgeIncidentIfNeeded(
      for: capability,
      statusCode: statusCode,
      recordedAt: recordedAt
    )
    reconcileAcpBridgeIncidentVisibility()
  }

  public var codexUnavailable: Bool {
    hostBridgeCapabilityState(for: "codex") != .ready
  }

  public var agentTuiUnavailable: Bool {
    hostBridgeCapabilityState(for: "agent-tui") != .ready
  }

  private var shouldPresentAcpBridgeBanner: Bool {
    guard let manifest = daemonStatus?.manifest, manifest.sandboxed else {
      return false
    }
    return hostBridgeCapabilityState(for: "codex") == .unavailable
  }

  func reconcileAcpBridgeIncidentVisibility() {
    guard acpBridgeHTTPIncident != nil else {
      return
    }
    guard shouldPresentAcpBridgeBanner else {
      acpBridgeHTTPIncident = nil
      return
    }
    scheduleUISync([.contentChrome])
  }

  func noteAcpBridgeRetryAttempt(
    for capability: String,
    recordedAt: Date = .now
  ) {
    guard capability == "codex", daemonStatus?.manifest?.sandboxed == true else {
      return
    }
    if let incident = acpBridgeHTTPIncident {
      acpBridgeHTTPIncident = incident.incrementingRetryCount()
    } else {
      acpBridgeHTTPIncident = AcpBridgeHTTPIncident(
        firstDetectedAt: recordedAt,
        retryCount: 1
      )
    }
  }

  private func recordAcpBridgeIncidentIfNeeded(
    for capability: String,
    statusCode: Int,
    recordedAt: Date = .now
  ) {
    guard capability == "codex", statusCode == 503, daemonStatus?.manifest?.sandboxed == true else {
      return
    }
    guard acpBridgeHTTPIncident == nil else { return }
    acpBridgeHTTPIncident = AcpBridgeHTTPIncident(
      firstDetectedAt: recordedAt,
      retryCount: 0
    )
  }
}

import Foundation

extension HarnessMonitorStore {
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
    guard hostBridgeCapabilityIssues[capability] != nil else {
      return
    }
    if forcedHostBridgeCapabilities.contains(capability) {
      return
    }
    hostBridgeCapabilityIssues.removeValue(forKey: capability)
  }

  func clearTransientHostBridgeIssues() {
    hostBridgeCapabilityIssues = hostBridgeCapabilityIssues.filter {
      forcedHostBridgeCapabilities.contains($0.key)
    }
  }

  public func markHostBridgeIssue(for capability: String, statusCode: Int) {
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
  }

  public var codexUnavailable: Bool {
    hostBridgeCapabilityState(for: "codex") != .ready
  }

  public var agentTuiUnavailable: Bool {
    hostBridgeCapabilityState(for: "agent-tui") != .ready
  }
}

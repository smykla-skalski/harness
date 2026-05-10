import HarnessMonitorKit
import SwiftUI

enum SessionStatusTone: Equatable {
  case success
  case muted

  var color: Color {
    switch self {
    case .success:
      HarnessMonitorTheme.success
    case .muted:
      HarnessMonitorTheme.disabledConnectionChrome
    }
  }
}

struct SessionStatusToken: Equatable {
  let label: String
  let tone: SessionStatusTone
  let accessibilityValue: String
  let help: String
}

struct SessionStatusStripState: Equatable {
  let bridge: SessionStatusToken?
  let mcp: SessionStatusToken?

  init(
    daemonOwnership: DaemonOwnership,
    bridgeRunning: Bool,
    mcpStatus: HarnessMonitorMCPStatusSnapshot,
    isMCPRegistryHostEnabled: Bool
  ) {
    if daemonOwnership == .managed {
      bridge = SessionStatusToken(
        label: "BRIDGE",
        tone: bridgeRunning ? .success : .muted,
        accessibilityValue: bridgeRunning ? "Host bridge running" : "Host bridge stopped",
        help: bridgeRunning ? "Built-in host bridge running." : "Built-in host bridge not running."
      )
    } else {
      bridge = nil
    }

    if isMCPRegistryHostEnabled {
      let isMCPReady: Bool
      if case .healthy = mcpStatus.runtimeState {
        isMCPReady = true
      } else {
        isMCPReady = false
      }
      mcp = SessionStatusToken(
        label: "MCP",
        tone: isMCPReady ? .success : .muted,
        accessibilityValue: isMCPReady ? "MCP ready" : "MCP unavailable",
        help: mcpStatus.detail
      )
    } else {
      mcp = nil
    }
  }

  var hasVisibleTokens: Bool {
    bridge != nil || mcp != nil
  }

  var showsSeparator: Bool {
    bridge != nil && mcp != nil
  }

  var stateMarkerValue: String {
    "bridge=\(bridgeState), mcp=\(mcpState)"
  }

  var accessibilityValue: String {
    let parts = [bridge?.accessibilityValue, mcp?.accessibilityValue].compactMap(\.self)
    if parts.isEmpty {
      return "No service indicators visible"
    }
    return parts.joined(separator: ", ")
  }

  var helpText: String {
    [bridge?.help, mcp?.help].compactMap(\.self).joined(separator: "\n")
  }

  private var bridgeState: String {
    guard let bridge else {
      return "hidden"
    }
    return bridge.tone == .success ? "running" : "stopped"
  }

  private var mcpState: String {
    guard let mcp else {
      return "hidden"
    }
    return mcp.tone == .success ? "ready" : "unavailable"
  }
}

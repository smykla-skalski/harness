import HarnessMonitorKit
import SwiftUI

enum AgentCapabilityAvailabilityState {
  case projectAccessAvailable
  case checkingAccess
  case setupRequired
  case bridgeAccessRequired
  case terminalOnly
  case unavailable

  var title: String {
    switch self {
    case .projectAccessAvailable:
      "Project access available"
    case .checkingAccess:
      "Checking access"
    case .setupRequired:
      "Setup required"
    case .bridgeAccessRequired:
      "Bridge access required"
    case .terminalOnly:
      "Terminal only"
    case .unavailable:
      "Unavailable"
    }
  }

  var compactTitle: String {
    switch self {
    case .projectAccessAvailable:
      "Ready"
    case .checkingAccess:
      "Checking"
    case .setupRequired:
      "Setup needed"
    case .bridgeAccessRequired:
      "Bridge required"
    case .terminalOnly:
      "Terminal only"
    case .unavailable:
      "Unavailable"
    }
  }

  var symbolName: String {
    switch self {
    case .projectAccessAvailable:
      "checkmark.circle.fill"
    case .checkingAccess:
      "clock.fill"
    case .setupRequired:
      "wrench.and.screwdriver.fill"
    case .bridgeAccessRequired:
      "link.badge.plus"
    case .terminalOnly:
      "terminal"
    case .unavailable:
      "xmark.circle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .projectAccessAvailable:
      HarnessMonitorTheme.success
    case .terminalOnly:
      HarnessMonitorTheme.accent
    case .checkingAccess, .unavailable:
      HarnessMonitorTheme.secondaryInk
    case .setupRequired, .bridgeAccessRequired:
      HarnessMonitorTheme.caution
    }
  }
}

struct AgentCapabilityOption: Identifiable, Equatable {
  let id: String
  let title: String
  let transportChoices: [AgentCapabilityTransportChoice]
  let doctorProbe: AcpDoctorProbe?
  let probe: AcpRuntimeProbe?
  let installHint: String?
  let sandboxed: Bool
  let acpHostBridgeReady: Bool

  var isEnabled: Bool {
    transportChoices.contains(where: isEnabled)
  }

  var hasPendingAcpProbe: Bool {
    acpChoice != nil && !sandboxed && probe == nil
  }

  var statusText: String {
    availabilityState.title
  }

  var accessibilityLabel: String {
    "\(title), \(statusText.lowercased())"
  }

  var installAccessibilityHint: String? {
    guard showsInstallCTA else { return nil }
    return "Copies install instructions for \(title)"
  }

  var doctorProbeText: String? {
    guard let probeCommand else { return nil }
    let probeStatus =
      if requiresBridgeAccess {
        "Bridge access required"
      } else if showsInstallCTA {
        "Setup required"
      } else if let probe, let version = probe.version, !version.isEmpty {
        "Installed \(version)"
      } else if probe != nil {
        "Installed"
      } else {
        "Checking access"
      }
    return "Setup check: \(probeCommand) · \(probeStatus)"
  }

  var installActionTitle: String {
    "Copy install instructions"
  }

  var showsInstallCTA: Bool {
    guard let acpChoice, !isEnabled(acpChoice) else { return false }
    guard !sandboxed || !acpHostBridgeReady else { return false }
    return probe?.binaryPresent == false
  }

  var probeCommand: String? {
    guard let doctorProbe else { return nil }
    return ([doctorProbe.command] + doctorProbe.args).joined(separator: " ")
  }

  var acpChoice: AgentCapabilityTransportChoice? {
    transportChoices.first { $0.id.isAcp }
  }

  var requiresBridgeAccess: Bool {
    sandboxed && !acpHostBridgeReady && acpChoice != nil
  }

  var availabilityState: AgentCapabilityAvailabilityState {
    if showsInstallCTA {
      return .setupRequired
    }
    if hasPendingAcpProbe {
      return .checkingAccess
    }
    if requiresBridgeAccess {
      return .bridgeAccessRequired
    }
    if let acpChoice, isEnabled(acpChoice) {
      return .projectAccessAvailable
    }
    if isEnabled {
      return .terminalOnly
    }
    return .unavailable
  }

  var projectAccessGuidanceText: String? {
    switch availabilityState {
    case .projectAccessAvailable:
      nil
    case .checkingAccess:
      "Project access is still being checked."
    case .setupRequired:
      "Install the \(title) CLI to add project access here."
    case .bridgeAccessRequired:
      "Turn on bridge access to use project access here."
    case .terminalOnly:
      transportChoices.contains(where: { $0.id.isAcp })
        ? "Project access isn't available here yet."
        : "This provider opens in Terminal only."
    case .unavailable:
      installHint ?? "This provider isn't available here yet."
    }
  }

  func normalizedSelection(for selection: AgentLaunchSelection) -> AgentLaunchSelection {
    let preferred = transportChoice(for: selection)
    if isEnabled(preferred) {
      return preferred.id
    }
    return transportChoices.first(where: isEnabled)?.id ?? transportChoices[0].id
  }

  func transportChoice(for selection: AgentLaunchSelection) -> AgentCapabilityTransportChoice {
    transportChoices.first { $0.id == selection } ?? transportChoices[0]
  }

  func isEnabled(_ choice: AgentCapabilityTransportChoice) -> Bool {
    switch choice.id {
    case .tui:
      return true
    case .acp:
      if sandboxed {
        return acpHostBridgeReady
      }
      return probe?.binaryPresent == true
    }
  }
}

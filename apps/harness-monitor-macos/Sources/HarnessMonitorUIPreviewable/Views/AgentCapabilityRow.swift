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

struct AgentCapabilityTransportChoice: Identifiable, Hashable {
  let id: AgentLaunchSelection
  let title: String
  let capabilities: [String]

  var capabilityLabels: [String] {
    capabilities.map(Self.humanCapabilityLabel(for:))
  }

  var capabilitySummary: String {
    let labels = capabilityLabels.filter { !$0.isEmpty }.prefix(3)
    return labels.isEmpty ? title : labels.joined(separator: ", ")
  }

  private static func humanCapabilityLabel(for capability: String) -> String {
    switch capability {
    case "fs.read":
      "filesystem read"
    case "fs.write":
      "filesystem write"
    case "terminal.spawn":
      "terminal spawn"
    case "terminal.create":
      "terminal create"
    case "streaming":
      "streaming"
    case "multi-turn":
      "multi-turn"
    case "requires-network":
      "network access"
    default:
      capability.replacingOccurrences(of: ".", with: " ")
    }
  }
}

struct AgentCapabilityRow: View {
  let option: AgentCapabilityOption
  @Binding var selection: AgentLaunchSelection
  @State private var diagnosticsExpanded = false

  private var normalizedSelection: AgentLaunchSelection {
    option.normalizedSelection(for: selection)
  }

  private var currentChoice: AgentCapabilityTransportChoice {
    option.transportChoice(for: normalizedSelection)
  }

  private var accessibilityCapabilityTags: [String] {
    option.acpChoice?.capabilityLabels ?? capabilityTags
  }

  private var capabilityTags: [String] {
    currentChoice.capabilityLabels
  }

  private var accessibilityCapabilitySummary: String {
    accessibilityCapabilityTags.joined(separator: ", ")
  }

  private var accessibilityRowLabel: String {
    "\(option.accessibilityLabel), capabilities: \(accessibilityCapabilitySummary)"
  }

  private var currentChoiceIsEnabled: Bool {
    option.isEnabled(currentChoice)
  }

  private var unavailableReason: String? {
    if case .acp = currentChoice.id {
      return option.projectAccessGuidanceText
    }
    return nil
  }

  private var statusTint: Color {
    option.availabilityState.tint
  }

  private var installHintText: String {
    option.probe?.installHint
      ?? option.installHint
      ?? option.installAccessibilityHint
      ?? option.installActionTitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      leadingColumn
      diagnosticsDisclosure
      transportColumn
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityRowLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentCapabilityRow(option.id))
  }

  private var leadingColumn: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      titleRow
      capabilitySummaryRow
      unavailableReasonRow()
      installActionRow()
    }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(option.title)
        .scaledFont(.body.weight(.semibold))
      Text(option.statusText)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(statusTint)
        .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
        .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
        .background(statusTint.opacity(0.14), in: Capsule())
    }
  }

  private var capabilitySummaryRow: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(currentChoice.capabilitySummary)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)

      if let transportAvailabilityText {
        Text(transportAvailabilityText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
          .accessibilityIdentifier(transportAvailabilityText)
      }
    }
  }

  private var transportAvailabilityText: String? {
    switch option.availabilityState {
    case .projectAccessAvailable:
      if !currentChoice.id.isAcp {
        return "Project access is also available."
      }
      return "Starts with project access available."
    case .checkingAccess, .setupRequired, .bridgeAccessRequired:
      if !currentChoice.id.isAcp {
        return option.projectAccessGuidanceText
      }
      return nil
    case .terminalOnly, .unavailable:
      return option.projectAccessGuidanceText
    }
  }

  @ViewBuilder
  private func unavailableReasonRow() -> some View {
    if !currentChoiceIsEnabled, let unavailableReason {
      Text(unavailableReason)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.caution)
        .lineLimit(2)
    }
  }

  @ViewBuilder
  private func installActionRow() -> some View {
    if option.showsInstallCTA {
      HarnessMonitorActionButton(
        title: option.installActionTitle,
        tint: HarnessMonitorTheme.caution,
        variant: .prominent,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentCapabilityInstallButton(
          option.id
        )
      ) {
        HarnessMonitorClipboard.copy(installHintText)
      }
      .help(installHintText)
      .accessibilityHint(option.installAccessibilityHint ?? "")
    }
  }

  private var transportColumn: some View {
    VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(option.transportChoices) { choice in
        transportButton(choice)
      }
    }
  }

  private func transportButton(_ choice: AgentCapabilityTransportChoice) -> some View {
    let isSelected = normalizedSelection == choice.id
    let isChoiceEnabled = option.isEnabled(choice)
    return Button {
      selection = choice.id
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        Text(choice.title)
      }
    }
    .harnessActionButtonStyle(
      variant: isSelected ? .prominent : .bordered,
      tint: isSelected ? nil : .secondary
    )
    .disabled(!isChoiceEnabled)
    .accessibilityLabel("\(option.title), \(choice.title)")
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityHint(
      isChoiceEnabled ? "" : (unavailableReason ?? "Unavailable")
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentCapabilityTransportButton(
        option.id,
        transportID: choice.id.accessibilityIDComponent
      )
    )
  }

  @ViewBuilder private var diagnosticsDisclosure: some View {
    if let doctorProbeText = option.doctorProbeText {
      if diagnosticsExpanded {
        Text(doctorProbeText)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(3)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentCapabilityProbe(option.id))
      }

      Button(diagnosticsExpanded ? "Hide setup details" : "Show setup details") {
        diagnosticsExpanded.toggle()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .accessibilityLabel(
        "\(diagnosticsExpanded ? "Hide" : "Show") setup details for \(option.title)"
      )
      .accessibilityHint(doctorProbeText)
      .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionDiagnosticsToggle(option.id))
    }
  }
}

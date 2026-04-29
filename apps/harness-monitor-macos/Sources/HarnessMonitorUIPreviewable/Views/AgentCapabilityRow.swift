import HarnessMonitorKit
import SwiftUI

struct AgentCapabilityOption: Identifiable, Equatable {
  let id: String
  let title: String
  let transportChoices: [AgentCapabilityTransportChoice]
  let probe: AcpRuntimeProbe?
  let installHint: String?
  let sandboxed: Bool
  let acpHostBridgeReady: Bool

  var isEnabled: Bool {
    transportChoices.contains(where: isEnabled)
  }

  var statusText: String {
    if showsInstallCTA {
      return "Install required"
    }
    if transportChoices.contains(where: { $0.id.isAcp }) {
      return isEnabled ? "Ready" : "Unavailable"
    }
    return "Terminal ready"
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
      if sandboxed, !acpHostBridgeReady, transportChoices.contains(where: { $0.id.isAcp }) {
        "Host bridge required"
      } else if showsInstallCTA {
        "Missing"
      } else if let probe, let version = probe.version, !version.isEmpty {
        "Installed \(version)"
      } else if probe != nil {
        "Installed"
      } else {
        "Probe pending"
      }
    return "Doctor probe: \(probeCommand) · \(probeStatus)"
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
    guard let probe else { return nil }
    return ([probe.command] + probe.args).joined(separator: " ")
  }

  var acpChoice: AgentCapabilityTransportChoice? {
    transportChoices.first { $0.id.isAcp }
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
      return probe?.binaryPresent ?? true
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

  private var normalizedSelection: AgentLaunchSelection {
    option.normalizedSelection(for: selection)
  }

  private var currentChoice: AgentCapabilityTransportChoice {
    option.transportChoice(for: normalizedSelection)
  }

  private var capabilityTags: [String] {
    currentChoice.capabilityLabels
  }

  private var accessibilityCapabilitySummary: String {
    capabilityTags.joined(separator: ", ")
  }

  private var accessibilityRowLabel: String {
    "\(option.accessibilityLabel), capabilities: \(accessibilityCapabilitySummary)"
  }

  private var currentChoiceIsEnabled: Bool {
    option.isEnabled(currentChoice)
  }

  private var unavailableReason: String? {
    if case .acp = currentChoice.id, option.sandboxed, !option.acpHostBridgeReady {
      return
        "Filesystem + terminal tools require the ACP host bridge while the daemon runs sandboxed."
    }
    return option.installHint
  }

  private var statusTint: Color {
    option.showsInstallCTA ? HarnessMonitorTheme.caution : HarnessMonitorTheme.secondaryInk
  }

  private var installHintText: String {
    option.probe?.installHint
      ?? option.installHint
      ?? option.installAccessibilityHint
      ?? option.installActionTitle
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
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
        capabilityTagRow
        if let doctorProbeText = option.doctorProbeText {
          Text(doctorProbeText)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(2)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.agentCapabilityProbe(option.id)
            )
        }
        if !currentChoiceIsEnabled, let unavailableReason {
          Text(unavailableReason)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.caution)
            .lineLimit(2)
        }
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
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(option.transportChoices) { choice in
          transportButton(choice)
        }
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityRowLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentCapabilityRow(option.id))
  }

  @ViewBuilder private var capabilityTagRow: some View {
    if !capabilityTags.isEmpty {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(capabilityTags.prefix(3), id: \.self) { capability in
          Text(capability)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
            .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
            .background(HarnessMonitorTheme.secondaryInk.opacity(0.08), in: Capsule())
        }
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
  }
}

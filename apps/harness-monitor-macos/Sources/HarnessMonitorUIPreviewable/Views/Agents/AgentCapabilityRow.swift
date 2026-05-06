import HarnessMonitorKit
import SwiftUI

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

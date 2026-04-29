import HarnessMonitorKit
import SwiftUI

extension NewSessionSheetView {
  @MainActor var capabilityPickerSection: some View {
    fieldBlock(
      "Preferred first leader",
      help:
        "Pick the capability you want preselected when you open Agents after creating this session."
    ) {
      NewSessionCapabilityPickerList(
        options: agentCapabilityOptions,
        selection: $selectedLaunchSelection
      )
    }
  }
}

private struct NewSessionCapabilityPickerList: View {
  let options: [AgentCapabilityOption]
  @Binding var selection: AgentLaunchSelection

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(options) { option in
        NewSessionAgentCapabilityRow(
          option: option,
          selection: $selection
        )
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityPicker)
    .onChange(of: options, initial: true) { _, updatedOptions in
      let normalizedSelection = AgentsWindowView.normalizedLaunchSelection(
        options: updatedOptions,
        selection: selection,
        fallbackRuntime: selection.preferredRuntime
      )
      if normalizedSelection != selection {
        selection = normalizedSelection
      }
    }
  }
}

// Duplicate on purpose per UI-2 plan. Tripwire: extract only when a third caller appears
// or this copy stays materially identical to AgentsWindow for 60 days.
private struct NewSessionAgentCapabilityRow: View {
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

  private var accessibilityCapabilityTags: [String] {
    option.acpChoice?.capabilityLabels ?? capabilityTags
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
    // Keep this accessibility structure aligned with AgentCapabilityRow:
    // the row exposes a summary label, while the visible title/probe/buttons
    // remain individually discoverable for XCUI and VoiceOver navigation.
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      leadingColumn
      transportColumn
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityRowLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityRow(option.id))
  }

  private var leadingColumn: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      titleRow
      capabilityTagRow()
      probeRow()
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

  @ViewBuilder
  private func capabilityTagRow() -> some View {
    if !capabilityTags.isEmpty {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(capabilityTags.prefix(3), id: \.self) { capability in
          NewSessionCapabilityChip(title: capability)
        }
      }
    }
  }

  @ViewBuilder
  private func probeRow() -> some View {
    if let doctorProbeText = option.doctorProbeText {
      Text(doctorProbeText)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
        .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityProbe(option.id))
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
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(option.transportChoices) { choice in
        transportButton(choice)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
      HarnessMonitorAccessibility.newSessionCapabilityTransportButton(
        option.id,
        transportID: choice.id.accessibilityIDComponent
      )
    )
  }
}

private struct NewSessionCapabilityChip: View {
  let title: String

  var body: some View {
    Text(title)
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .padding(.horizontal, HarnessMonitorTheme.pillPaddingH)
      .padding(.vertical, HarnessMonitorTheme.pillPaddingV)
      .background(HarnessMonitorTheme.secondaryInk.opacity(0.08), in: Capsule())
      .accessibilityHidden(true)
  }
}

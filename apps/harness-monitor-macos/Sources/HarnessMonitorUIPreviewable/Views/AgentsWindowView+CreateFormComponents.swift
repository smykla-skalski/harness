import HarnessMonitorKit
import SwiftUI

struct AgentsCreateSectionCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(HarnessMonitorTheme.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .fill(HarnessMonitorTheme.ink.opacity(0.035))
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.6), lineWidth: 1)
      }
  }
}

struct AgentsCreateSectionHeading: View {
  let title: String
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.headline)
      Text(description)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct AgentsCreateFieldBlock<Content: View>: View {
  let title: String
  let help: String?
  private let content: Content

  init(
    title: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.help = help
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      content

      if let help {
        Text(help)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct AgentsCreateProviderRow: View {
  let option: AgentCapabilityOption
  @Binding var selection: AgentLaunchSelection

  private var normalizedSelection: AgentLaunchSelection {
    option.normalizedSelection(for: selection)
  }

  private var currentChoice: AgentCapabilityTransportChoice {
    option.transportChoice(for: normalizedSelection)
  }

  private var isSelected: Bool {
    option.transportChoices.contains(where: { $0.id == selection })
      || selection == normalizedSelection
  }

  private var capabilitySummary: String {
    let labels = option.acpChoice?.capabilityLabels ?? currentChoice.capabilityLabels
    return labels.joined(separator: ", ")
  }

  private var accessibilityRowLabel: String {
    "\(option.accessibilityLabel), capabilities: \(capabilitySummary)"
  }

  private var subtitle: String {
    if currentChoice.id.isAcp {
      return "Starts with project access ready."
    }
    if let acpChoice = option.acpChoice, option.isEnabled(acpChoice) {
      return "Starts in a terminal screen. Project access is also available."
    }
    if option.showsInstallCTA {
      return "Starts in a terminal screen. Install project access for richer project context."
    }
    return "Starts in a terminal screen."
  }

  private var statusTint: Color {
    if option.showsInstallCTA {
      return HarnessMonitorTheme.caution
    }
    if option.transportChoices.contains(where: { $0.id.isAcp }) {
      return option.isEnabled ? HarnessMonitorTheme.success : HarnessMonitorTheme.secondaryInk
    }
    return HarnessMonitorTheme.accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        selection = normalizedSelection
      } label: {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
              Text(option.title)
                .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
              Text(subtitle)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: HarnessMonitorTheme.spacingSM)

            AgentsCreateProviderStatusBadge(title: option.statusText, tint: statusTint)
          }

          Text(capabilitySummary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(2)
        }
        .padding(HarnessMonitorTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.1) : .clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .stroke(
              HarnessMonitorTheme.accent.opacity(0.45),
              lineWidth: 1.5
            )
            .opacity(isSelected ? 1 : 0)
        }
      }
      .harnessInteractiveCardButtonStyle(
        cornerRadius: HarnessMonitorTheme.cornerRadiusSM,
        tint: isSelected ? HarnessMonitorTheme.accent : nil,
        extraHoverHint: isSelected
      )
      .accessibilityLabel(option.title)
      .accessibilityHint("Select provider")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.segmentedOption(
          HarnessMonitorAccessibility.agentTuiRuntimePicker,
          option: option.title
        )
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityRowLabel)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentCapabilityRow(option.id))
  }
}

struct AgentsCreateProviderStatusBadge: View {
  let title: String
  let tint: Color

  var body: some View {
    Text(title)
      .scaledFont(.caption.weight(.semibold))
      .harnessPillPadding()
      .harnessContentPill(tint: tint)
  }
}

struct AgentsCreateTransportChoiceButton: View {
  let providerTitle: String
  let optionID: String
  let choice: AgentCapabilityTransportChoice
  let selection: Binding<AgentLaunchSelection>
  let isSelected: Bool
  let isEnabled: Bool
  let unavailableReason: String?

  private var shortTitle: String {
    choice.id.isAcp ? "Project Access" : "Terminal"
  }

  var body: some View {
    Button {
      selection.wrappedValue = choice.id
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        Text(shortTitle)
      }
      .frame(maxWidth: .infinity)
    }
    .harnessActionButtonStyle(
      variant: isSelected ? .prominent : .bordered,
      tint: isSelected ? nil : .secondary
    )
    .disabled(!isEnabled)
    .accessibilityLabel("\(providerTitle), \(choice.title)")
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityHint(isEnabled ? "" : (unavailableReason ?? "Unavailable"))
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentCapabilityTransportButton(
        optionID,
        transportID: choice.id.accessibilityIDComponent
      )
    )
  }
}

struct AgentsCreateDiagnosticsDisclosure: View {
  let option: AgentCapabilityOption
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Button(isExpanded ? "Hide diagnostics" : "Show diagnostics") {
        isExpanded.toggle()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .accessibilityLabel(
        "\(isExpanded ? "Hide" : "Show") diagnostics for \(option.title)"
      )
      .accessibilityHint(option.statusText)
      .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionDiagnosticsToggle(option.id))

      if isExpanded, let doctorProbeText = option.doctorProbeText {
        Text(doctorProbeText)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentCapabilityProbe(option.id))
      }
    }
  }
}

import HarnessMonitorKit
import SwiftUI

struct AgentsCreateSectionCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AgentsCreateProviderGridCard<Content: View>: View {
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
        .fill(HarnessMonitorTheme.ink.opacity(0.055))
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.8), lineWidth: 1)
      }
  }
}

struct AgentsCreateSectionHeading: View {
  let title: String
  let description: String?

  init(title: String, description: String? = nil) {
    self.title = title
    self.description = description
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)
      if let description {
        Text(description)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
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
    let subtitle: String
    if let projectAccessStatusText {
      subtitle = "\(primarySubtitle) \(projectAccessStatusText)"
    } else {
      subtitle = primarySubtitle
    }
    return [
      option.title,
      option.availabilityState.compactTitle,
      subtitle,
      "capabilities: \(capabilitySummary)",
    ].joined(separator: ", ")
  }

  private var primarySubtitle: String {
    currentChoice.id.isAcp ? "Starts via ACP" : "Starts in Terminal"
  }

  private var projectAccessStatusText: String? {
    guard option.acpChoice != nil else {
      return nil
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return "ACP is also available"
    case .checkingAccess:
      return "ACP is still being checked"
    case .setupRequired:
      return "ACP needs CLI setup"
    case .bridgeAccessRequired:
      return "ACP needs bridge setup"
    case .terminalOnly:
      return "ACP isn't available for this provider yet"
    case .unavailable:
      return
        option.projectAccessGuidanceText
        ?? "ACP isn't available for this provider yet"
    }
  }

  private var statusTint: Color {
    option.availabilityState.tint
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        selection = normalizedSelection
      } label: {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
              HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
                Text(option.title)
                  .scaledFont(.system(.headline, design: .rounded, weight: .semibold))

                if isSelected {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HarnessMonitorTheme.accent)
                    .accessibilityHidden(true)
                }
              }
              VStack(alignment: .leading, spacing: 2) {
                Text(primarySubtitle)
                  .scaledFont(.caption)
                  .lineLimit(1)
                  .allowsTightening(true)
                if let projectAccessStatusText {
                  Text(projectAccessStatusText)
                    .scaledFont(.caption)
                    .lineLimit(1)
                    .allowsTightening(true)
                }
              }
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            }

            Spacer(minLength: HarnessMonitorTheme.spacingSM)

            AgentsCreateProviderStatusBadge(
              title: option.availabilityState.compactTitle,
              tint: statusTint,
              systemImage: option.availabilityState.symbolName
            )
          }
        }
        .padding(HarnessMonitorTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.14) : .clear)
        }
        .overlay {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
            .stroke(
              HarnessMonitorTheme.accent.opacity(0.7),
              lineWidth: 1.75
            )
            .opacity(isSelected ? 1 : 0)
        }
      }
      .harnessInteractiveCardButtonStyle(
        cornerRadius: HarnessMonitorTheme.cornerRadiusSM,
        tint: isSelected ? HarnessMonitorTheme.accent : nil,
        extraHoverHint: isSelected
      )
      .accessibilityHidden(true)
      .harnessMCPButton(
        HarnessMonitorAccessibility.segmentedOption(
          HarnessMonitorAccessibility.agentTuiRuntimePicker,
          option: option.title
        ),
        label: option.title,
        hint: isSelected ? "Selected provider" : "Select provider",
        pressAction: { selection = normalizedSelection }
      )
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityRowLabel)
    .accessibilityHint(isSelected ? "Selected provider" : "Select provider")
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(.isButton)
    .harnessMCPRow(
      HarnessMonitorAccessibility.agentCapabilityRow(option.id),
      label: accessibilityRowLabel,
      value: isSelected ? "Selected" : "",
      pressAction: { selection = normalizedSelection }
    )
  }
}

struct AgentsCreateProviderStatusBadge: View {
  let title: String
  let tint: Color
  let systemImage: String

  var body: some View {
    Label(title, systemImage: systemImage)
      .scaledFont(.caption.weight(.semibold), maxScale: 1)
      .lineLimit(1)
      .allowsTightening(true)
      .fixedSize(horizontal: true, vertical: false)
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
    choice.id.isAcp ? "ACP" : "Terminal"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
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
      .harnessMCPButton(
        HarnessMonitorAccessibility.agentCapabilityTransportButton(
          optionID,
          transportID: choice.id.accessibilityIDComponent
        ),
        label: "\(providerTitle), \(choice.title)",
        value: isSelected ? "Selected" : "",
        hint: isEnabled ? "" : (unavailableReason ?? "Unavailable"),
        enabled: isEnabled,
        pressAction: { selection.wrappedValue = choice.id }
      )

      if !isEnabled, let unavailableReason {
        Text(unavailableReason)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AgentsCreateDiagnosticsDisclosure: View {
  let option: AgentCapabilityOption
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Button(isExpanded ? "Hide setup details" : "Show setup details") {
        isExpanded.toggle()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .accessibilityLabel(
        "\(isExpanded ? "Hide" : "Show") setup details for \(option.title)"
      )
      .accessibilityHint(option.statusText)
      .harnessMCPButton(
        HarnessMonitorAccessibility.newSessionDiagnosticsToggle(option.id),
        label: "\(isExpanded ? "Hide" : "Show") setup details for \(option.title)",
        hint: option.statusText,
        pressAction: { isExpanded.toggle() }
      )

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

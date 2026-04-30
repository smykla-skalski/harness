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
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(description)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct AgentsCreateSummaryFact: Identifiable, Equatable {
  let title: String
  let value: String

  var id: String { title }
}

struct AgentsCreateSummaryFactsView: View {
  let facts: [AgentsCreateSummaryFact]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingLG) {
        ForEach(facts) { fact in
          summaryFact(fact)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(facts) { fact in
          summaryFact(fact)
        }
      }
    }
  }

  private func summaryFact(_ fact: AgentsCreateSummaryFact) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(fact.title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(fact.value)
        .scaledFont(.body.weight(.semibold))
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
      return "Starts with project access."
    }
    if let projectAccessStatusText {
      return "Starts in Terminal. \(projectAccessStatusText)"
    }
    return "Starts in Terminal."
  }

  private var projectAccessStatusText: String? {
    guard option.acpChoice != nil else {
      return nil
    }

    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Project access is also available."
    case .checkingAccess:
      return "Project access is still being checked."
    case .setupRequired:
      return "Project access needs CLI setup."
    case .bridgeAccessRequired:
      return "Project access needs bridge setup."
    case .terminalOnly:
      return "Project access isn't available for this provider yet."
    case .unavailable:
      return option.projectAccessGuidanceText ?? "Project access isn't available for this provider yet."
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
              Text(subtitle)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: HarnessMonitorTheme.spacingSM)

            AgentsCreateProviderStatusBadge(
              title: option.availabilityState.compactTitle,
              tint: statusTint,
              systemImage: option.availabilityState.symbolName
            )
          }

          Text("Capabilities: \(capabilitySummary)")
            .scaledFont(.caption2)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(2)
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
      .accessibilityLabel(option.title)
      .accessibilityHint(isSelected ? "Selected provider" : "Select provider")
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
  let systemImage: String

  var body: some View {
    Label(title, systemImage: systemImage)
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
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.agentCapabilityTransportButton(
          optionID,
          transportID: choice.id.accessibilityIDComponent
        )
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

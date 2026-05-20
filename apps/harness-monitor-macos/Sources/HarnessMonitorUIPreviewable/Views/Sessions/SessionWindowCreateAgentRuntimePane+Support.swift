import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateSectionCard<Content: View>: View {
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

struct SessionWindowCreateSectionHeading: View {
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

struct SessionWindowCreateFieldBlock<Content: View>: View {
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

struct SessionWindowCreateProviderButtonList: View {
  let options: [AgentCapabilityOption]
  let selectedProviderID: String?
  let onSelect: (AgentCapabilityOption) -> Void

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(options) { option in
        Button {
          onSelect(option)
        } label: {
          SessionWindowCreateProviderListRow(
            option: option,
            isSelected: selectedProviderID == option.id
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(SessionWindowCreateProviderListRow.accessibilityLabel(for: option))
        .accessibilityValue(selectedProviderID == option.id ? "Selected" : "")
        .accessibilityHint("Chooses \(option.title)")
      }
    }
  }
}

struct SessionWindowCreateProviderListRow: View {
  let option: AgentCapabilityOption
  let isSelected: Bool

  private var rowTint: Color {
    isSelected ? HarnessMonitorTheme.accent.opacity(0.10) : .clear
  }

  private var availableModes: [SessionWindowCreateProviderMode] {
    Self.availableModes(for: option)
  }

  private var statusTint: Color {
    option.availabilityState.tint
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: Self.providerIconName(for: option))
        .scaledFont(.body)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(width: 16, alignment: .center)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          Text(option.title)
            .scaledFont(.body.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(HarnessMonitorTheme.ink)

          Spacer(minLength: HarnessMonitorTheme.spacingSM)

          if availableModes.isEmpty {
            Text(option.availabilityState.compactTitle)
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(statusTint)
              .multilineTextAlignment(.trailing)
              .lineLimit(1)
              .truncationMode(.tail)
              .fixedSize(horizontal: true, vertical: false)
          } else {
            HStack(spacing: HarnessMonitorTheme.spacingXS) {
              ForEach(availableModes) { mode in
                SessionWindowCreateProviderModeBadge(mode: mode)
              }
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
          }
        }

        Text(Self.providerSubtitle(for: option))
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowTint)
    .clipShape(.rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  static func providerSubtitle(for option: AgentCapabilityOption) -> String {
    if option.codexChoice != nil {
      return codexProviderSubtitle(for: option)
    }
    return standardProviderSubtitle(for: option)
  }

  private static func codexProviderSubtitle(for option: AgentCapabilityOption) -> String {
    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Codex app server is available."
    case .bridgeAccessRequired:
      return "Codex needs bridge access."
    case .terminalOnly:
      return "Codex opens in Terminal only."
    default:
      return option.projectAccessGuidanceText ?? "Codex is not available here yet."
    }
  }

  private static func standardProviderSubtitle(for option: AgentCapabilityOption) -> String {
    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Terminal and ACP are available."
    case .checkingAccess:
      return "ACP is still being checked."
    case .setupRequired:
      if option.bundledWithHarness {
        return "ACP ships with Harness."
      }
      return "ACP needs CLI setup."
    case .bridgeAccessRequired:
      return "ACP needs bridge access."
    case .terminalOnly:
      if option.acpChoice != nil {
        return "ACP is not available here yet."
      }
      return "This provider opens in Terminal only."
    case .unavailable:
      return option.projectAccessGuidanceText ?? "This provider is not available here yet."
    }
  }

  static func providerSummary(for option: AgentCapabilityOption) -> String {
    providerSubtitle(for: option)
  }

  static func availableModes(
    for option: AgentCapabilityOption
  ) -> [SessionWindowCreateProviderMode] {
    option.transportChoices.compactMap { choice in
      guard option.isEnabled(choice) else { return nil }
      if choice.id.isCodexNative {
        return .codex
      }
      return choice.id.isAcp ? .acp : .tui
    }
  }

  static func modeSummary(for option: AgentCapabilityOption) -> String {
    let modes = availableModes(for: option).map(\.rawValue)
    switch modes.count {
    case 0:
      return option.availabilityState.compactTitle
    case 1:
      return "Mode \(modes[0])"
    case 2:
      return "Modes \(modes[0]) and \(modes[1])"
    default:
      let prefix = modes.dropLast().joined(separator: ", ")
      return "Modes \(prefix), and \(modes[modes.count - 1])"
    }
  }

  static func providerIconName(for option: AgentCapabilityOption) -> String {
    switch option.id {
    case "codex":
      return "terminal"
    case "claude":
      return "sparkles"
    case "gemini":
      return "diamond"
    case "copilot":
      return "paperplane"
    case "vibe":
      return "waveform"
    case "opencode":
      return "chevron.left.forwardslash.chevron.right"
    default:
      return "terminal"
    }
  }

  static func accessibilityLabel(for option: AgentCapabilityOption) -> String {
    [option.title, modeSummary(for: option), providerSubtitle(for: option)]
      .compactMap { $0 }
      .joined(separator: ", ")
  }
}

enum SessionWindowCreateProviderMode: String, Identifiable {
  case codex = "App Server"
  case acp = "ACP"
  case tui = "TUI"

  var id: String { rawValue }

  var fill: Color {
    switch self {
    case .codex:
      HarnessMonitorTheme.warmAccent
    case .acp:
      HarnessMonitorTheme.success
    case .tui:
      HarnessMonitorTheme.accent
    }
  }

  var foreground: Color {
    HarnessMonitorProminentButtonContrast.foreground(for: fill)
  }
}

private struct SessionWindowCreateProviderModeBadge: View {
  let mode: SessionWindowCreateProviderMode
  private let cornerRadius: CGFloat = 8
  private let horizontalPadding: CGFloat = 6
  private let verticalPadding: CGFloat = 2

  var body: some View {
    Text(mode.rawValue)
      .font(.system(.caption2, design: .rounded, weight: .semibold))
      .foregroundStyle(mode.foreground)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(mode.fill)
      }
      .accessibilityHidden(true)
  }
}

struct SessionWindowCreateTransportChoiceButton: View {
  let providerTitle: String
  let choice: AgentCapabilityTransportChoice
  let isSelected: Bool
  let isEnabled: Bool
  let showsUnavailableReasonText: Bool
  let unavailableReason: String?
  let onSelect: () -> Void

  private var shortTitle: String {
    if choice.id.isCodexNative {
      return "Codex App Server"
    }
    return choice.id.isAcp ? "ACP" : "Terminal"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Button {
        onSelect()
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
      .accessibilityLabel("\(providerTitle), \(shortTitle)")
      .accessibilityValue(isSelected ? "Selected" : "")
      .accessibilityHint(
        isEnabled ? "" : (unavailableReason ?? "Unavailable")
      )

      if showsUnavailableReasonText, !isEnabled, let unavailableReason {
        Text(unavailableReason)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionWindowCreateDiagnosticsDisclosure: View {
  let option: AgentCapabilityOption
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isExpanded = false

  var body: some View {
    if let doctorProbeText = option.doctorProbeText {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Button(isExpanded ? "Hide setup details" : "Show setup details") {
          if reduceMotion {
            isExpanded.toggle()
          } else {
            withAnimation(.easeOut(duration: 0.18)) {
              isExpanded.toggle()
            }
          }
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityLabel(
          "\(isExpanded ? "Hide" : "Show") setup details for \(option.title)"
        )
        .accessibilityHint(doctorProbeText)

        if isExpanded {
          Text(doctorProbeText)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
  }
}

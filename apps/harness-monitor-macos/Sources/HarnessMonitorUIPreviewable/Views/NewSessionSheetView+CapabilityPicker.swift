import HarnessMonitorKit
import SwiftUI

extension NewSessionSheetView {
  @MainActor var preferredLeaderSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      fieldBlock(
        "Launch with",
        help: "Choose the provider that starts first when the session begins."
      ) {
        NewSessionPreferredLeaderPicker(
          options: agentCapabilityOptions,
          selection: preferredLaunchSelectionBinding
        )
      }

      if !providerAttentionOptions.isEmpty {
        NewSessionProviderDetailsDisclosure(options: providerAttentionOptions)
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityPickerSection)
  }

  private var providerAttentionOptions: [AgentCapabilityOption] {
    let selectedLeaderID =
      agentCapabilityOptions.first { option in
        option.transportChoices.contains { $0.id == preferredLaunchSelection }
      }?.id
    return agentCapabilityOptions.filter { option in
      option.needsAttentionInNewSession && option.id != selectedLeaderID
    }
  }
}

private struct NewSessionPreferredLeaderPicker: View {
  let options: [AgentCapabilityOption]
  @Binding var selection: AgentLaunchSelection

  var body: some View {
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(options) { option in
        AgentCapabilityRow(
          option: option,
          selection: $selection
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityPicker)
  }
}

private struct NewSessionProviderDetailsDisclosure: View {
  let options: [AgentCapabilityOption]
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isExpanded = false

  private var summary: String {
    var installCount = 0
    var checkingCount = 0
    var bridgeAccessCount = 0
    var otherCount = 0

    for option in options {
      if option.showsInstallCTA {
        installCount += 1
      } else if option.requiresBridgeAccessInNewSession {
        bridgeAccessCount += 1
      } else if option.hasPendingAcpProbe {
        checkingCount += 1
      } else {
        otherCount += 1
      }
    }

    switch (installCount, checkingCount, bridgeAccessCount, otherCount, options.count) {
    case (0, 0, 0, 0, 1):
      return "1 provider needs attention."
    case (0, 0, 0, 0, let total):
      return "\(total) providers need attention."
    case (0, let checking, 0, 0, _):
      return
        checking == 1
        ? "1 provider is still checking access."
        : "\(checking) providers are still checking access."
    case (let install, 0, 0, 0, _):
      return install == 1 ? "1 provider needs setup." : "\(install) providers need setup."
    case (0, 0, let bridgeAccess, 0, _):
      return
        bridgeAccess == 1
        ? "1 provider needs bridge access."
        : "\(bridgeAccess) providers need bridge access."
    default:
      var parts: [String] = []
      if installCount > 0 {
        parts.append("\(installCount) need setup")
      }
      if checkingCount > 0 {
        parts.append("\(checkingCount) still checking access")
      }
      if bridgeAccessCount > 0 {
        parts.append("\(bridgeAccessCount) need bridge access")
      }
      if otherCount > 0 {
        parts.append("\(otherCount) need review")
      }
      return parts.joined(separator: ", ") + "."
    }
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(options) { option in
          NewSessionProviderSetupRow(option: option)
        }
      }
      .padding(.top, HarnessMonitorTheme.spacingSM)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text("Providers needing attention")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(summary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
    }
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.18),
      value: isExpanded
    )
  }
}

private struct NewSessionProviderSetupRow: View {
  let option: AgentCapabilityOption

  private var presentation: NewSessionCapabilityPresentation {
    option.newSessionPresentation()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(option.title)
          .scaledFont(.body.weight(.semibold))
        NewSessionProviderStatusBadge(
          title: presentation.title,
          tint: presentation.tint
        )
      }

      Text(presentation.detail)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)

      NewSessionProviderSupportActions(option: option)
    }
    .newSessionProviderCard(tint: presentation.tint)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityRow(option.id))
  }
}

private struct NewSessionProviderSupportActions: View {
  let option: AgentCapabilityOption
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var showDiagnostics = false

  private var installHintText: String {
    option.probe?.installHint
      ?? option.installHint
      ?? option.installAccessibilityHint
      ?? option.installActionTitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if option.showsInstallCTA {
        Button(option.installActionTitle) {
          HarnessMonitorClipboard.copy(installHintText)
        }
        .harnessActionButtonStyle(variant: .prominent, tint: .orange)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityHint(option.installAccessibilityHint ?? option.statusText)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.agentCapabilityInstallButton(option.id)
        )
      }

      if let doctorProbeText = option.doctorProbeText, option.needsAttentionInNewSession {
        Button(showDiagnostics ? "Hide setup details" : "Show setup details") {
          if reduceMotion {
            showDiagnostics.toggle()
          } else {
            withAnimation(.easeOut(duration: 0.18)) {
              showDiagnostics.toggle()
            }
          }
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityLabel(
          "\(showDiagnostics ? "Hide" : "Show") setup details for \(option.title)"
        )
        .accessibilityHint(doctorProbeText)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.newSessionDiagnosticsToggle(option.id)
        )

        if showDiagnostics {
          Text(doctorProbeText)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.newSessionCapabilityProbe(option.id)
            )
        }
      }
    }
  }
}

private struct NewSessionProviderStatusBadge: View {
  let title: String
  let tint: Color

  var body: some View {
    Text(title)
      .scaledFont(.caption.weight(.semibold))
      .harnessPillPadding()
      .harnessContentPill(tint: tint)
  }
}

private struct NewSessionCapabilityPresentation {
  let title: String
  let detail: String
  let tint: Color
}

extension AgentCapabilityOption {
  fileprivate var needsAttentionInNewSession: Bool {
    showsInstallCTA || hasPendingAcpProbe || requiresBridgeAccessInNewSession || !isEnabled
  }

  fileprivate var requiresBridgeAccessInNewSession: Bool {
    requiresBridgeAccess
  }

  fileprivate func newSessionPresentation(
    for selection: AgentLaunchSelection? = nil
  ) -> NewSessionCapabilityPresentation {
    let choice = selection.map(transportChoice(for:)) ?? transportChoices[0]
    let startsWithProjectAccess = choice.id.isAcp && isEnabled(choice)

    let launchText =
      startsWithProjectAccess
      ? "Starts with project access available."
      : "Opens in Terminal."

    let detail: String =
      switch availabilityState {
      case .projectAccessAvailable:
        startsWithProjectAccess ? launchText : "\(launchText) Project access is also available."
      case .checkingAccess:
        startsWithProjectAccess
          ? "Project access is still being checked."
          : "\(launchText) Project access is still being checked."
      case .setupRequired:
        startsWithProjectAccess
          ? "Set up project access to launch this provider with project access."
          : "\(launchText) Set up project access when you're ready."
      case .bridgeAccessRequired:
        "Turn on bridge access to use project access while the daemon runs sandboxed."
      case .terminalOnly:
        "Opens in Terminal only."
      case .unavailable:
        projectAccessGuidanceText ?? "This provider isn't available in New Session yet."
      }

    return NewSessionCapabilityPresentation(
      title: availabilityState.title,
      detail: detail,
      tint: availabilityState.tint
    )
  }
}

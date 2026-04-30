import HarnessMonitorKit
import SwiftUI

extension NewSessionSheetView {
  @MainActor var preferredLeaderSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      fieldBlock(
        "Start with",
        help: "Choose the leader that opens first when the session starts."
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
    var hostBridgeCount = 0
    var otherCount = 0

    for option in options {
      if option.showsInstallCTA {
        installCount += 1
      } else if option.requiresHostBridgeInNewSession {
        hostBridgeCount += 1
      } else if option.hasPendingAcpProbe {
        checkingCount += 1
      } else {
        otherCount += 1
      }
    }

    switch (installCount, checkingCount, hostBridgeCount, otherCount, options.count) {
    case (0, 0, 0, 0, 1):
      return "1 provider needs attention."
    case (0, 0, 0, 0, let total):
      return "\(total) providers need attention."
    case (0, let checking, 0, 0, _):
      return
        checking == 1
        ? "1 provider is still checking."
        : "\(checking) providers are still checking."
    case (let install, 0, 0, 0, _):
      return install == 1 ? "1 provider needs setup." : "\(install) providers need setup."
    case (0, 0, let hostBridge, 0, _):
      return
        hostBridge == 1
        ? "1 provider needs host bridge."
        : "\(hostBridge) providers need host bridge."
    default:
      var parts: [String] = []
      if installCount > 0 {
        parts.append("\(installCount) need setup")
      }
      if checkingCount > 0 {
        parts.append("\(checkingCount) still checking")
      }
      if hostBridgeCount > 0 {
        parts.append("\(hostBridgeCount) need host bridge")
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
        Text("Provider details")
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
        Button(showDiagnostics ? "Hide diagnostics" : "Show diagnostics") {
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
          "\(showDiagnostics ? "Hide" : "Show") diagnostics for \(option.title)"
        )
        .accessibilityHint(option.statusText)
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
    showsInstallCTA || hasPendingAcpProbe || requiresHostBridgeInNewSession || !isEnabled
  }

  fileprivate var requiresHostBridgeInNewSession: Bool {
    sandboxed && !acpHostBridgeReady && acpChoice != nil
  }

  fileprivate func newSessionPresentation(
    for selection: AgentLaunchSelection? = nil
  ) -> NewSessionCapabilityPresentation {
    let choice = selection.map(transportChoice(for:)) ?? transportChoices[0]
    let acpIsReady = acpChoice.map(isEnabled) == true
    let startsWithTools = choice.id.isAcp

    let launchText =
      startsWithTools
      ? "Starts with filesystem + terminal tools."
      : "Starts in Terminal screen."

    if !isEnabled {
      if requiresHostBridgeInNewSession {
        return NewSessionCapabilityPresentation(
          title: "Host bridge required",
          detail:
            "Filesystem + terminal tools require the ACP host bridge while the daemon runs sandboxed.",
          tint: HarnessMonitorTheme.caution
        )
      }

      if hasPendingAcpProbe {
        return NewSessionCapabilityPresentation(
          title: "Checking",
          detail: "Harness is still checking whether this provider can be used from New Session.",
          tint: HarnessMonitorTheme.secondaryInk
        )
      }

      if showsInstallCTA {
        return NewSessionCapabilityPresentation(
          title: "Setup required",
          detail: installHint ?? "Install this provider to make it available in New Session.",
          tint: HarnessMonitorTheme.caution
        )
      }

      return NewSessionCapabilityPresentation(
        title: "Unavailable",
        detail: installHint ?? "This provider is not available in New Session yet.",
        tint: HarnessMonitorTheme.secondaryInk
      )
    }

    if requiresHostBridgeInNewSession {
      return NewSessionCapabilityPresentation(
        title: "Terminal ready",
        detail:
          """
          \(launchText) Filesystem + terminal tools require the ACP host bridge \
          while the daemon runs sandboxed.
          """,
        tint: HarnessMonitorTheme.caution
      )
    }

    if showsInstallCTA {
      return NewSessionCapabilityPresentation(
        title: "Terminal ready",
        detail: "\(launchText) Install filesystem + terminal tools for richer project access.",
        tint: HarnessMonitorTheme.caution
      )
    }

    if hasPendingAcpProbe {
      let checkingDetail =
        startsWithTools
        ? "Filesystem + terminal tools are still being checked."
        : "Harness is still checking filesystem + terminal tools."
      return NewSessionCapabilityPresentation(
        title: "Checking tools",
        detail: "\(launchText) \(checkingDetail)",
        tint: HarnessMonitorTheme.secondaryInk
      )
    }

    if acpIsReady {
      let readyDetail =
        startsWithTools
        ? launchText
        : "\(launchText) Filesystem + terminal tools are also available."
      return NewSessionCapabilityPresentation(
        title: "Ready with tools",
        detail: readyDetail,
        tint: HarnessMonitorTheme.success
      )
    }

    return NewSessionCapabilityPresentation(
      title: "Terminal ready",
      detail: launchText,
      tint: HarnessMonitorTheme.success
    )
  }
}

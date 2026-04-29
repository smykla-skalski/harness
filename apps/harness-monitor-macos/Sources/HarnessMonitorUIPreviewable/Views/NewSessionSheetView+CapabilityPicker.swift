import HarnessMonitorKit
import SwiftUI

extension NewSessionSheetView {
  @MainActor var preferredLeaderSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      fieldBlock(
        "Preferred first leader",
        help: "Choose which ready leader is preselected after this session is created."
      ) {
        NewSessionPreferredLeaderPicker(
          options: agentCapabilityOptions,
          selection: $selectedLaunchSelection
        )
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityPickerSection)
  }
}

private struct NewSessionPreferredLeaderPicker: View {
  private struct Choice: Identifiable {
    let id: String
    let title: String
    let status: String
    let selection: AgentLaunchSelection
  }

  let options: [AgentCapabilityOption]
  @Binding var selection: AgentLaunchSelection

  private var choices: [Choice] {
    var seen: Set<String> = []
    var result: [Choice] = []

    for option in options {
      guard option.isEnabled else { continue }
      let defaultChoice = option.transportChoices[0].id
      let normalized = option.normalizedSelection(for: defaultChoice)
      let key = normalized.storageKey
      guard seen.insert(key).inserted else { continue }
      result.append(
        Choice(
          id: key,
          title: option.title,
          status: option.statusText,
          selection: normalized
        )
      )
    }

    return result
  }

  private var activeSelection: AgentLaunchSelection {
    if choices.contains(where: { $0.selection == selection }) {
      return selection
    }
    return choices.first?.selection ?? selection
  }

  var body: some View {
    Picker(
      "Preferred first leader",
      selection: Binding(
        get: { activeSelection },
        set: { selection = $0 }
      )
    ) {
      ForEach(choices) { choice in
        Text("\(choice.title) (\(choice.status))")
          .tag(choice.selection)
      }
    }
    .pickerStyle(.menu)
    .harnessNativeFormControl()
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCapabilityPicker)
  }
}

struct NewSessionRuntimeStatusSection: View {
  let options: [AgentCapabilityOption]
  @Binding var selection: AgentLaunchSelection

  private var readyOptions: [AgentCapabilityOption] {
    options.filter(\.isEnabled)
  }

  private var installRequiredOptions: [AgentCapabilityOption] {
    options.filter(\.showsInstallCTA)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
      runtimeBlock(
        title: "Ready providers",
        help: "Available now for session startup."
      ) {
        ForEach(readyOptions) { option in
          NewSessionRuntimeStatusRow(
            option: option,
            selection: $selection
          )
        }
      }

      runtimeBlock(
        title: "Needs install",
        help: "Install these providers to enable filesystem + terminal tools."
      ) {
        if installRequiredOptions.isEmpty {
          Text("All detected providers are install-ready.")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        } else {
          ForEach(installRequiredOptions) { option in
            NewSessionRuntimeStatusRow(
              option: option,
              selection: $selection
            )
          }
        }
      }
    }
  }

  private func runtimeBlock<Content: View>(
    title: String,
    help: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Text(title)
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(help)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      content()
    }
  }
}

private struct NewSessionRuntimeStatusRow: View {
  let option: AgentCapabilityOption
  @Binding var selection: AgentLaunchSelection
  @State private var showDiagnostics = false

  private var recommendedSelection: AgentLaunchSelection {
    option.normalizedSelection(for: option.transportChoices[0].id)
  }

  private var preferredTransportTitle: String {
    option.transportChoice(for: recommendedSelection).title
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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingXS) {
            Text(option.title)
              .scaledFont(.body.weight(.semibold))
            Text(option.statusText)
              .scaledFont(.caption.weight(.semibold))
              .foregroundStyle(statusTint)
          }
          Text(preferredTransportTitle)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Group {
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
          } else {
            Button("Use") {
              selection = recommendedSelection
            }
            .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
          }
        }
      }

      if option.doctorProbeText != nil {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          Button(showDiagnostics ? "Hide diagnostics" : "Show diagnostics") {
            withAnimation(.easeOut(duration: 0.2)) {
              showDiagnostics.toggle()
            }
          }
          .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.newSessionDiagnosticsToggle(option.id)
          )
          Spacer(minLength: 0)
        }

        if showDiagnostics, let doctorProbeText = option.doctorProbeText {
          Text(doctorProbeText)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.newSessionCapabilityProbe(option.id)
            )
        }
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

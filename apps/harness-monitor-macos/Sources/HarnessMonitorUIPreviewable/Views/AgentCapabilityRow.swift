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
    isEnabled ? "Ready" : "Install required"
  }

  var accessibilityLabel: String {
    "\(title), \(statusText.lowercased())"
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

  var capabilitySummary: String {
    let labels =
      capabilities
      .filter { !$0.isEmpty }
      .prefix(3)
      .map { $0.replacingOccurrences(of: ".", with: " ") }
    return labels.isEmpty ? title : labels.joined(separator: ", ")
  }
}

struct AgentCapabilityRow: View {
  let option: AgentCapabilityOption
  @Binding var selection: AgentLaunchSelection

  private var normalizedSelection: AgentLaunchSelection {
    option.normalizedSelection(for: selection)
  }

  private var selectedChoice: AgentCapabilityTransportChoice {
    option.transportChoice(for: normalizedSelection)
  }

  private var selectedChoiceIsEnabled: Bool {
    option.isEnabled(selectedChoice)
  }

  private var unavailableReason: String? {
    if case .acp = selectedChoice.id, option.sandboxed, !option.acpHostBridgeReady {
      return "Filesystem + terminal tools require the ACP host bridge while the daemon runs sandboxed."
    }
    return option.installHint
  }

  private var selectedChoiceIconName: String {
    normalizedSelection == selectedChoice.id ? "checkmark.circle.fill" : "circle"
  }

  private var pickerSelection: Binding<AgentLaunchSelection> {
    Binding(
      get: { normalizedSelection },
      set: { selection = $0 }
    )
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(option.title)
          .scaledFont(.body.weight(.semibold))
        Text(selectedChoice.capabilitySummary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
        if !selectedChoiceIsEnabled, let unavailableReason {
          Text(unavailableReason)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.caution)
            .lineLimit(2)
        }
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if option.transportChoices.count > 1 {
        Picker("Capability", selection: pickerSelection) {
          ForEach(option.transportChoices) { choice in
            Text(choice.title)
              .tag(choice.id)
              .disabled(!option.isEnabled(choice))
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(!option.isEnabled)
        .accessibilityLabel(option.title)
        .accessibilityValue(selectedChoice.title)
      } else {
        Button {
          selection = selectedChoice.id
        } label: {
          Image(systemName: selectedChoiceIconName)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(!selectedChoiceIsEnabled)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.statusText)
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(option.accessibilityLabel)
    .disabled(!option.isEnabled)
  }
}

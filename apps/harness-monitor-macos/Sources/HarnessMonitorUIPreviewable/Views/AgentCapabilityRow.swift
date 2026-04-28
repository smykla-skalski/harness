import HarnessMonitorKit
import SwiftUI

struct AgentCapabilityOption: Identifiable, Equatable {
  let id: String
  let title: String
  let transportChoices: [AgentCapabilityTransportChoice]
  let probe: AcpRuntimeProbe?
  let installHint: String?

  var isEnabled: Bool {
    probe?.binaryPresent ?? true
  }

  var statusText: String {
    guard let probe else { return "Ready" }
    return probe.binaryPresent ? "Ready" : "Install required"
  }

  var accessibilityLabel: String {
    "\(title), \(statusText.lowercased())"
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

  private var selectedChoice: AgentCapabilityTransportChoice {
    option.transportChoices.first { $0.id == selection } ?? option.transportChoices[0]
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
        if !option.isEnabled, let installHint = option.installHint {
          Text(installHint)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.caution)
            .lineLimit(2)
        }
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if option.transportChoices.count > 1 {
        Picker("Capability", selection: $selection) {
          ForEach(option.transportChoices) { choice in
            Text(choice.title).tag(choice.id)
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
          Image(systemName: selection == selectedChoice.id ? "checkmark.circle.fill" : "circle")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(!option.isEnabled)
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

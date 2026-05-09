import SwiftUI

struct SessionWindowCreateFormCapabilityPicker: View {
  let options: [AgentCapabilityOption]
  @Binding var selection: AgentLaunchSelection
  let isLoading: Bool
  let validationMessage: String?

  var body: some View {
    Section {
      if isLoading {
        Label("Checking available agent capabilities", systemImage: "clock")
          .scaledFont(.callout)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Checking available agent capabilities")
      }
      ForEach(options) { option in
        AgentCapabilityRow(option: option, selection: $selection)
      }
    } header: {
      Text("Capability")
        .harnessNativeFormSectionHeader()
    }
    .accessibilityHint(validationMessage ?? "")
  }
}

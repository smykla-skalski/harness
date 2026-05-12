import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateTransportChoicesGroup: View, Equatable {
  let option: AgentCapabilityOption
  let selectedSelection: AgentLaunchSelection
  let usesVerticalLayout: Bool
  let onSelectChoice: (AgentLaunchSelection) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.option == rhs.option
      && lhs.selectedSelection == rhs.selectedSelection
      && lhs.usesVerticalLayout == rhs.usesVerticalLayout
  }

  var body: some View {
    let layout =
      usesVerticalLayout
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM))
      : AnyLayout(HStackLayout(alignment: .top, spacing: HarnessMonitorTheme.spacingSM))

    layout {
      ForEach(option.transportChoices) { transportChoice in
        SessionWindowCreateTransportChoiceButton(
          providerTitle: option.title,
          choice: transportChoice,
          isSelected: selectedSelection == transportChoice.id,
          isEnabled: option.isEnabled(transportChoice),
          unavailableReason: SessionWindowCreateFormCatalogs.unavailableReason(
            for: option,
            choice: transportChoice
          ),
          onSelect: { onSelectChoice(transportChoice.id) }
        )
      }
    }
  }
}

struct SessionWindowCreateRuntimeModelPickerRow: View, Equatable {
  let catalog: RuntimeModelCatalog
  let modelPickerValue: String
  let onModelChange: (String) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.catalog == rhs.catalog
      && lhs.modelPickerValue == rhs.modelPickerValue
  }

  private var modelSelection: Binding<String> {
    Binding(
      get: { modelPickerValue },
      set: { onModelChange($0) }
    )
  }

  var body: some View {
    Picker("Model", selection: modelSelection) {
      ForEach(catalog.models) { model in
        Text(model.displayName).tag(model.id)
      }
      Text("Custom...")
        .tag(SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag)
    }
    .pickerStyle(.menu)
    .harnessNativeFormControl()
    .accessibilityLabel("Runtime model")
  }
}

struct SessionWindowCreateRuntimeCustomModelRow: View, Equatable {
  let customModel: String
  let onCustomModelChange: (String) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.customModel == rhs.customModel
  }

  private var customModelBinding: Binding<String> {
    Binding(
      get: { customModel },
      set: { onCustomModelChange($0) }
    )
  }

  var body: some View {
    LabeledContent("Custom model") {
      TextField("", text: customModelBinding)
        .harnessNativeTextField()
        .accessibilityLabel("Custom runtime model")
    }
  }
}

struct SessionWindowCreateRuntimeEffortRow: View, Equatable {
  let values: [String]
  let selectedEffort: String
  let onEffortChange: (String) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.values == rhs.values
      && lhs.selectedEffort == rhs.selectedEffort
  }

  private var effortSelection: Binding<String> {
    Binding(
      get: { selectedEffort },
      set: { onEffortChange($0) }
    )
  }

  var body: some View {
    Picker("Effort", selection: effortSelection) {
      ForEach(values, id: \.self) { level in
        Text(level.capitalized).tag(level)
      }
    }
    .pickerStyle(.segmented)
    .harnessNativeFormControl()
    .accessibilityLabel("Runtime effort")
  }
}

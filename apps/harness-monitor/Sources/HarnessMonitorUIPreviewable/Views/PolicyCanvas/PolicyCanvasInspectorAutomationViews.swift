import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

extension PolicyCanvasEditForm {
  @ViewBuilder
  func nodeAutomationBindingControls(_ node: PolicyCanvasNode) -> some View {
    if node.kind == .source || node.automationBinding != nil {
      PolicyCanvasInspectorSection(
        title: node.kind == .source ? "Automation Policy" : "Automation Component"
      ) {
        Toggle(
          node.kind == .source ? "Compile policy" : "Contribute to connected policy",
          isOn: Binding(
            get: { node.automationBinding != nil },
            set: { isEnabled in
              let defaultBinding: PolicyGraphAutomationBinding =
                node.kind == .source ? .canvasDefault() : .canvasComponent()
              viewModel.commitSelectedNodeAutomationBinding(
                isEnabled ? (node.automationBinding ?? defaultBinding) : nil
              )
            }
          )
        )
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("automation-enabled")
        )

        if let binding = node.automationBinding {
          nodeAutomationBindingDetailControls(node: node, binding: binding)
        }
      }
    }
  }

  var canvasAutomationPolicySummaryRow: some View {
    PolicyCanvasInspectorRow(
      label: "Automation",
      value: viewModel.automationPolicyCompilation.summaryText
    )
  }

  @ViewBuilder
  func nodeAutomationPolicyPreview(_ node: PolicyCanvasNode) -> some View {
    if let policy = viewModel.automationPolicyCompilation.policy(compiledFrom: node.id) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Canvas Automation")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        PolicyCanvasInspectorRow(label: "Source", value: policy.eventSource.title)
        PolicyCanvasInspectorRow(label: "Priority", value: "\(policy.priority)")
        PolicyCanvasInspectorRow(
          label: "Content",
          value: policy.match.contentKinds.map(\.title).sorted().joined(separator: ", ")
        )
        PolicyCanvasInspectorRow(
          label: "Actions",
          value: policy.executionActions.map(\.title).joined(separator: ", ")
        )
        PolicyCanvasInspectorRow(
          label: "After",
          value: policy.postprocessors.map(\.title).joined(separator: ", ")
        )
      }
    }
  }

  private func automationSourcePicker(
    _ binding: PolicyGraphAutomationBinding
  ) -> some View {
    PolicyCanvasInspectorField(label: "Event") {
      Picker(
        "Automation event source",
        selection: Binding(
          get: { binding.resolvedEventSource },
          set: { commitAutomationBinding(binding.replacingSource($0)) }
        )
      ) {
        ForEach(AutomationPolicyEventSource.allCases) { source in
          Text(source.title).tag(source)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("automation-source")
      )
    }
  }

  private func automationPriorityStepper(
    _ binding: PolicyGraphAutomationBinding
  ) -> some View {
    PolicyCanvasInspectorField(label: "Priority") {
      Stepper(
        value: Binding(
          get: { binding.priority ?? 1 },
          set: { priority in
            var next = binding
            next.priority = priority
            commitAutomationBinding(next)
          }
        ),
        in: 1...999
      ) {
        Text("\(binding.priority ?? 1)")
          .scaledFont(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("automation-priority")
      )
    }
  }

  private func automationToggleGroup<Value>(
    title: String,
    values: [Value],
    contains: @escaping (Value) -> Bool,
    set: @escaping (Value, Bool) -> Void
  ) -> some View where Value: Hashable, Value: PolicyCanvasAutomationTitledValue {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      ForEach(values, id: \.self) { value in
        Toggle(
          value.title,
          isOn: Binding(get: { contains(value) }, set: { set(value, $0) })
        )
        .scaledFont(.caption)
      }
    }
  }

  private func automationSourceAppControls(
    _ binding: PolicyGraphAutomationBinding
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      PolicyCanvasInspectorField(label: "Apps") {
        Picker(
          "Source app mode",
          selection: Binding(
            get: { binding.resolvedSourceAppMode },
            set: { commitAutomationBinding(binding.settingSourceAppMode($0)) }
          )
        ) {
          ForEach(AutomationSourceAppMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("automation-app-mode")
        )
      }

      PolicyCanvasInspectorCommitTextField(
        label: "Allowed bundle IDs",
        placeholder: "Allowed bundle IDs",
        value: binding.allowedBundleIdentifiers.joined(separator: ", "),
        focusField: .automationAllowedApps,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("automation-allowed-apps"),
        commit: { commitAutomationBinding(binding.settingAllowedBundleIdentifiers($0)) }
      )
      .disabled(binding.resolvedSourceAppMode != .allowedOnly)

      PolicyCanvasInspectorCommitTextField(
        label: "Denied bundle IDs",
        placeholder: "Denied bundle IDs",
        value: binding.deniedBundleIdentifiers.joined(separator: ", "),
        focusField: .automationDeniedApps,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("automation-denied-apps"),
        commit: { commitAutomationBinding(binding.settingDeniedBundleIdentifiers($0)) }
      )
    }
  }

  @ViewBuilder
  private func nodeAutomationBindingDetailControls(
    node: PolicyCanvasNode,
    binding: PolicyGraphAutomationBinding
  ) -> some View {
    let usesSourceDefaults = node.kind == .source
    if node.kind == .source {
      automationSourcePicker(binding)
      automationPriorityStepper(binding)
    } else {
      Text(automationComponentDescription)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
    }
    automationBindingToggleGroups(binding, usesSourceDefaults: usesSourceDefaults)
    if binding.resolvedEventSource == .reviewScreenshotPaste {
      automationReviewScreenshotControls(binding)
    }
    automationSourceAppControls(binding)
  }

  private func automationBindingToggleGroups(
    _ binding: PolicyGraphAutomationBinding,
    usesSourceDefaults: Bool
  ) -> some View {
    Group {
      automationToggleGroup(
        title: "Content",
        values: AutomationClipboardContentKind.allCases,
        contains: {
          usesSourceDefaults
            ? binding.resolvedContentKinds.contains($0)
            : binding.selectedContentKinds.contains($0)
        },
        set: { commitAutomationBinding(binding.settingContentKind($0, enabled: $1)) }
      )
      automationToggleGroup(
        title: "Safety",
        values: AutomationPolicyPreprocessor.allCases,
        contains: {
          usesSourceDefaults
            ? binding.resolvedPreprocessors.contains($0)
            : binding.selectedPreprocessors.contains($0)
        },
        set: { commitAutomationBinding(binding.settingPreprocessor($0, enabled: $1)) }
      )
      automationToggleGroup(
        title: "Actions",
        values: AutomationPolicyAction.allCases,
        contains: {
          usesSourceDefaults
            ? binding.resolvedActions.contains($0)
            : binding.selectedActions.contains($0)
        },
        set: { commitAutomationBinding(binding.settingAction($0, enabled: $1)) }
      )
      automationToggleGroup(
        title: "After Actions",
        values: AutomationPolicyPostprocessor.allCases,
        contains: {
          usesSourceDefaults
            ? binding.resolvedPostprocessors.contains($0)
            : binding.selectedPostprocessors.contains($0)
        },
        set: { commitAutomationBinding(binding.settingPostprocessor($0, enabled: $1)) }
      )
    }
  }

  private func automationReviewScreenshotControls(
    _ binding: PolicyGraphAutomationBinding
  ) -> some View {
    let ocr = binding.resolvedOCRConfiguration ?? AutomationPolicyOCRConfiguration()
    let extraction =
      binding.resolvedReviewPullRequestExtraction ?? ReviewPullRequestExtractionConfiguration()
    return VStack(alignment: .leading, spacing: 8) {
      Text("Screenshot PR Extraction")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      automationReviewOCRControls(ocr: ocr, binding: binding)
      automationReviewExtractionFields(extraction: extraction, binding: binding)
      automationReviewExtractionToggles(extraction: extraction, binding: binding)
    }
  }

  private func automationReviewExtractionToggles(
    extraction: ReviewPullRequestExtractionConfiguration,
    binding: PolicyGraphAutomationBinding
  ) -> some View {
    Group {
      Toggle(
        "Auto-copy",
        isOn: Binding(
          get: { extraction.autoCopy },
          set: { commitAutomationBinding(binding.settingReviewAutoCopy($0)) }
        )
      )
      .scaledFont(.caption)
      Toggle(
        "Show sheet",
        isOn: Binding(
          get: { extraction.showSheet },
          set: { commitAutomationBinding(binding.settingReviewShowSheet($0)) }
        )
      )
      .scaledFont(.caption)
      Toggle(
        "Number memory",
        isOn: Binding(
          get: { extraction.numberMemoryEnabled },
          set: { commitAutomationBinding(binding.settingReviewNumberMemoryEnabled($0)) }
        )
      )
      .scaledFont(.caption)
    }
  }

  func automationPickerField<Value>(
    label: String,
    title: String,
    values: [Value],
    selection: Value,
    set: @escaping (Value) -> Void
  ) -> some View where Value: Hashable, Value: PolicyCanvasAutomationTitledValue {
    PolicyCanvasInspectorField(label: label) {
      Picker(
        title,
        selection: Binding(
          get: { selection },
          set: { set($0) }
        )
      ) {
        ForEach(values, id: \.self) { value in
          Text(value.title).tag(value)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
    }
  }

  func commitAutomationBinding(_ binding: PolicyGraphAutomationBinding) {
    viewModel.commitSelectedNodeAutomationBinding(binding)
  }

  private var automationComponentDescription: String {
    "Connect this component from an automation source to include it in the enforced policy."
  }
}

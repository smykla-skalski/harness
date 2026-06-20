import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

/// Identifies a pending scenario add/edit. `scenarioId` is nil for a new scenario
/// and doubles (via `id`) as the `.sheet(item:)` identity, so switching from add
/// to a specific edit re-presents a fresh form.
struct PolicyCanvasScenarioEditRequest: Identifiable, Equatable {
  let scenarioId: String?
  let name: String
  let input: PolicyInput

  var id: String { scenarioId ?? "new" }
}

/// Add/edit form for a confidence scenario. Owns a value-type draft seeded from
/// the request, requires a non-empty name, and on save hands the resolved
/// PolicyInput back to the host. Follows the policy-canvas sheet convention: an
/// injected dismiss closure and a custom footer rather than a navigation toolbar.
struct PolicyCanvasScenarioEditorSheet: View {
  let request: PolicyCanvasScenarioEditRequest
  let confirm: @MainActor (String, PolicyInput) -> Void
  let dismiss: @MainActor () -> Void

  @State private var draft: PolicyCanvasScenarioEditorDraft

  init(
    request: PolicyCanvasScenarioEditRequest,
    confirm: @escaping @MainActor (String, PolicyInput) -> Void,
    dismiss: @escaping @MainActor () -> Void
  ) {
    self.request = request
    self.confirm = confirm
    self.dismiss = dismiss
    _draft = State(
      initialValue: PolicyCanvasScenarioEditorDraft(name: request.name, input: request.input)
    )
  }

  private var isNew: Bool { request.scenarioId == nil }
  private var canSave: Bool { !draft.trimmedName.isEmpty }

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        PolicyCanvasScenarioEditorForm(draft: $draft)
          .padding(16)
      }
      footer
    }
    .frame(minWidth: 480, idealWidth: 520, maxWidth: 600, minHeight: 460)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasScenarioEditorSheet)
    .harnessMCPElementTrackingEnabled(false)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(isNew ? "Add scenario" : "Edit scenario")
        .scaledFont(.title3.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
      Text("Define the inputs to test against the draft. Leave evidence on Any to keep it unset.")
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Rectangle().fill(PolicyCanvasVisualStyle.separator).frame(height: 1)
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Spacer(minLength: 16)

      Button("Cancel", action: dismiss)
        .keyboardShortcut(.cancelAction)
        .harnessActionButtonStyle(variant: .bordered)
        .controlSize(.small)

      Button(isNew ? "Add" : "Save") {
        confirm(draft.trimmedName, draft.resolvedInput())
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .harnessActionButtonStyle(variant: .prominent, tint: PolicyCanvasVisualStyle.readyTint)
      .controlSize(.small)
      .disabled(!canSave)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(PolicyCanvasVisualStyle.chromeBackground)
    .overlay(alignment: .top) {
      Rectangle().fill(PolicyCanvasVisualStyle.separator).frame(height: 1)
    }
  }
}

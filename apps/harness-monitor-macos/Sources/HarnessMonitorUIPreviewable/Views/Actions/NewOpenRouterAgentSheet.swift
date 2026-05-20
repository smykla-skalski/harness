import HarnessMonitorKit
import SwiftUI

@MainActor
public struct NewOpenRouterAgentSheet: View {
  private enum Field: Hashable {
    case prompt
    case customModel
  }

  public let store: HarnessMonitorStore
  public let sessionID: String
  @Environment(\.dismiss)
  private var dismiss
  @State private var prompt = ""
  @State private var availableModels: [OpenRouterModelEntry] = []
  @State private var selectedModelID = "anthropic/claude-3.7-sonnet"
  @State private var customModelID = ""
  @State private var useCustomModel = false
  @State private var validationMessage: String?
  @State private var isLoadingModels = false
  @State private var isSubmitting = false
  @FocusState private var focusedField: Field?

  public init(store: HarnessMonitorStore, sessionID: String) {
    self.store = store
    self.sessionID = sessionID
  }

  private var canSubmit: Bool {
    !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSubmitting
      && !effectiveModelID.isEmpty
  }

  private var effectiveModelID: String {
    if useCustomModel {
      return customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return selectedModelID
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
          formContent
          if let validationMessage {
            validationBanner(validationMessage)
          }
        }
        .padding(HarnessMonitorTheme.spacingLG)
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.newOpenRouterAgentSheet)
    .task {
      focusedField = .prompt
      await loadModels()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("New OpenRouter Session")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Start OpenRouter Session")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var formContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
      fieldBlock(
        "Prompt",
        help: "Required. This starts an OpenRouter session in the selected harness session."
      ) {
        HarnessMonitorMultilineTextField(
          placeholder: "Ask the model...",
          text: $prompt,
          minHeight: 120,
          focusedField: $focusedField,
          equals: .prompt,
          accessibilityLabel: "Prompt",
          accessibilityHint: "Required. This starts an OpenRouter session."
        )
      }

      fieldBlock("Model") {
        if isLoadingModels {
          HStack {
            ProgressView().controlSize(.small)
            Text("Loading model catalog from OpenRouter...")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        } else if availableModels.isEmpty {
          TextField("Model ID", text: $selectedModelID)
            .harnessNativeTextField()
            .focused($focusedField, equals: .customModel)
        } else {
          Picker(modelMenuTitle, selection: $selectedModelID) {
            ForEach(availableModels) { model in
              Text(model.name ?? model.id).tag(model.id)
            }
            Text("Custom...").tag("__custom__")
          }
          .pickerStyle(.menu)
          .harnessNativeFormControl()
          .onChange(of: selectedModelID) { _, newValue in
            useCustomModel = newValue == "__custom__"
          }
          if useCustomModel {
            TextField("Provider-specific model id", text: $customModelID)
              .harnessNativeTextField()
              .focused($focusedField, equals: .customModel)
          }
        }
      }
    }
  }

  private var modelMenuTitle: String {
    if useCustomModel {
      let trimmed = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Custom model" : trimmed
    }
    return availableModels.first { $0.id == selectedModelID }?.name ?? selectedModelID
  }

  private var footer: some View {
    HStack {
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      Button {
        Task { await submit() }
      } label: {
        Label("Start Session", systemImage: "play.circle.fill")
          .scaledFont(.body.weight(.semibold))
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!canSubmit)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private func fieldBlock<Content: View>(
    _ title: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
      if let help {
        Text(help)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func validationBanner(_ message: String) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(HarnessMonitorTheme.danger)
      Text(message)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private func loadModels() async {
    isLoadingModels = true
    defer { isLoadingModels = false }
    let models = await store.fetchOpenRouterModels()
    availableModels = models
    if let first = models.first, !models.contains(where: { $0.id == selectedModelID }) {
      selectedModelID = first.id
    }
  }

  private func submit() async {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      validationMessage = "Prompt is required."
      focusedField = .prompt
      return
    }
    let modelID = effectiveModelID
    guard !modelID.isEmpty else {
      validationMessage = "Pick a model or enter a custom id."
      focusedField = .customModel
      return
    }
    isSubmitting = true
    defer { isSubmitting = false }
    let snapshot = await store.startOpenRouterRun(
      prompt: trimmedPrompt,
      model: modelID,
      sessionID: sessionID
    )
    if snapshot != nil {
      dismiss()
    }
  }
}

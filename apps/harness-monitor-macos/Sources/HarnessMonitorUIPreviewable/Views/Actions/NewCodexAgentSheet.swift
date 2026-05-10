import HarnessMonitorKit
import SwiftUI

@MainActor
struct NewCodexAgentSheet: View {
  private enum Field: Hashable {
    case prompt
    case customModel
  }

  let store: HarnessMonitorStore
  let sessionID: String
  @Environment(\.dismiss)
  private var dismiss
  @State private var prompt = ""
  @State private var mode: CodexRunMode = .report
  @State private var runtimeModelCatalogs: [RuntimeModelCatalog] = []
  @State private var selectedModelID = ""
  @State private var customModelID = ""
  @State private var selectedEffort = ""
  @State private var validationMessage: String?
  @FocusState private var focusedField: Field?

  private var codexCatalog: RuntimeModelCatalog? {
    runtimeModelCatalogs.first { $0.runtime == AgentTuiRuntime.codex.rawValue }
  }

  private var effortValues: [String] {
    guard let codexCatalog else {
      return selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
        ? SessionWindowCreateFormCatalogs.allEffortLevels : []
    }
    return SessionWindowCreateFormCatalogs.effortValues(
      catalog: codexCatalog,
      selectedModelID: selectedModelID
    )
  }

  private var canSubmit: Bool {
    !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var normalizedEffort: String {
    let trimmedEffort = selectedEffort.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedEffort.isEmpty else {
      return SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues)
    }
    guard effortValues.isEmpty || effortValues.contains(trimmedEffort) else {
      return SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues)
    }
    return trimmedEffort
  }

  var body: some View {
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.newCodexAgentSheet)
    .task {
      await loadCodexCatalogIfNeeded()
      focusedField = .prompt
    }
    .onChange(of: selectedModelID) { _, _ in
      selectedEffort = normalizedEffort
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("New Codex Agent")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Create Codex Agent")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      if let sessionTitle = store.sessionIndex.sessionSummary(for: sessionID)?.displayTitle {
        Text(sessionTitle)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var formContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
      fieldBlock(
        "Prompt",
        help: "Required. This starts a Codex run in the current session."
      ) {
        TextEditor(text: $prompt)
          .harnessNativeFormControl()
          .frame(minHeight: 120)
          .focused($focusedField, equals: .prompt)
      }

      fieldBlock("Run mode") {
        Picker("Run mode", selection: $mode) {
          ForEach(CodexRunMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .harnessNativeFormControl()
      }

      fieldBlock("Model") {
        if let codexCatalog {
          Picker(selectedModelMenuTitle(catalog: codexCatalog), selection: $selectedModelID) {
            ForEach(codexCatalog.models) { model in
              Text(model.displayName).tag(model.id)
            }
            Text("Custom...")
              .tag(SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag)
          }
          .pickerStyle(.menu)
          .harnessNativeFormControl()

          if selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
            TextField("Provider-specific model id", text: $customModelID)
              .harnessNativeTextField()
              .focused($focusedField, equals: .customModel)
          }
        } else {
          TextField("Model (optional)", text: $customModelID)
            .harnessNativeTextField()
            .focused($focusedField, equals: .customModel)
        }
      }

      if !effortValues.isEmpty {
        fieldBlock("Effort") {
          Picker("Effort", selection: $selectedEffort) {
            ForEach(effortValues, id: \.self) { level in
              Text(level.capitalized).tag(level)
            }
          }
          .pickerStyle(.segmented)
          .harnessNativeFormControl()
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Cancel", role: .cancel) {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)

      Spacer()

      Button {
        Task { await submit() }
      } label: {
        Label("Create Codex Agent", systemImage: "plus.circle.fill")
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

  private func selectedModelMenuTitle(catalog: RuntimeModelCatalog) -> String {
    if selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag {
      let trimmedCustomModelID = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedCustomModelID.isEmpty ? "Custom model" : trimmedCustomModelID
    }

    return
      catalog.models.first { $0.id == selectedModelID }?.displayName
      ?? selectedModelID
  }

  private func loadCodexCatalogIfNeeded() async {
    let runtimeModels = await store.fetchRuntimeModelCatalogs()
    runtimeModelCatalogs = runtimeModels
    if let codexCatalog {
      selectedModelID = codexCatalog.default
      selectedEffort = SessionWindowCreateFormCatalogs.defaultEffortLevel(from: effortValues)
    }
  }

  private func submit() async {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      validationMessage = "Codex prompt is required."
      focusedField = .prompt
      return
    }

    let modelSelection = SessionWindowCreateFormCatalogs.effectiveModelSelection(
      pickerValue: codexCatalog == nil ? "" : selectedModelID,
      customValue: customModelID,
      catalogDefault: codexCatalog?.default ?? ""
    )
    let effort = normalizedEffort

    guard
      await store.startCodexRunSnapshot(
        prompt: trimmedPrompt,
        mode: mode,
        model: modelSelection.id,
        effort: effort.isEmpty ? nil : effort,
        allowCustomModel: modelSelection.allowCustomModel,
        sessionID: sessionID
      ) != nil
    else {
      return
    }

    LaunchPresetDefaults.write(
      LaunchPresetSnapshot(
        mode: .codex,
        codexMode: mode.rawValue,
        codexModel:
          selectedModelID == SessionWindowCreateFormCatalogs.RuntimeCustomModel.tag
          ? nil : modelSelection.id,
        customCodexModel: modelSelection.allowCustomModel ? modelSelection.id : nil,
        codexEffort: effort.isEmpty ? nil : effort
      )
    )
    dismiss()
  }
}

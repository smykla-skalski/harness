import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateFormMetrics: Equatable {
  let formPadding: CGFloat
  let promptMinHeight: CGFloat
  let submitButtonMinHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    formPadding = 24 * min(scale, 1.3)
    promptMinHeight = max(90, 90 * min(scale, 1.25))
    submitButtonMinHeight = scale >= 1.45 ? 44 : 0
  }
}

struct SessionWindowCreateForm: View {
  let store: HarnessMonitorStore
  @Bindable var state: SessionWindowStateCache
  let draft: SessionCreateDraft
  @Environment(\.fontScale)
  private var fontScale
  @State private var validationResult: SessionWindowCreateFormValidationResult?
  @State private var agentCapabilityOptions: [AgentCapabilityOption] = []
  @State private var isLoadingAgentCapabilities = false
  @FocusState private var focusedField: SessionWindowCreateFormField?

  private var title: Binding<String> {
    Binding(
      get: { draft.title },
      set: { updateDraft(title: $0) }
    )
  }

  private var prompt: Binding<String> {
    Binding(
      get: { draft.prompt },
      set: { updateDraft(prompt: $0) }
    )
  }

  private var launchSelection: Binding<AgentLaunchSelection> {
    Binding(
      get: { draft.launchSelection },
      set: { updateDraft(runtime: $0.storageKey) }
    )
  }

  private var taskSeverity: Binding<TaskSeverity> {
    Binding(
      get: { draft.taskSeverity },
      set: { updateDraft(taskSeverity: $0) }
    )
  }

  private var activeAgentCapabilityOptions: [AgentCapabilityOption] {
    agentCapabilityOptions.isEmpty
      ? SessionWindowCreateFormCatalogs.fallbackAgentOptions(store: store)
      : agentCapabilityOptions
  }

  private var metrics: SessionWindowCreateFormMetrics {
    SessionWindowCreateFormMetrics(fontScale: fontScale)
  }

  var body: some View {
    Form {
      Section(draft.kind.title) {
        TextField("Name", text: title)
          .scaledFont(.body)
          .focused($focusedField, equals: .name)
          .accessibilityLabel("\(draft.kind.title) name")
          .accessibilityHint(validationMessage(for: .name) ?? "")
        TextEditor(text: prompt)
          .scaledFont(.body)
          .frame(minHeight: metrics.promptMinHeight)
          .focused($focusedField, equals: .prompt)
          .accessibilityLabel("Prompt")
      }
      if draft.kind == .agent {
        SessionWindowCreateFormCapabilityPicker(
          options: activeAgentCapabilityOptions,
          selection: launchSelection,
          isLoading: isLoadingAgentCapabilities,
          validationMessage: validationMessage(for: .capability)
        )
      }
      if draft.kind == .task {
        Section("Task Details") {
          Picker("Severity", selection: taskSeverity) {
            ForEach(TaskSeverity.allCases, id: \.rawValue) { severity in
              Text(severity.title).tag(severity)
            }
          }
          .accessibilityLabel("Task severity")
        }
      }
      if let validationResult {
        Section {
          Text(validationResult.message)
            .scaledFont(.callout)
            .foregroundStyle(.red)
            .accessibilityLabel("Validation error: \(validationResult.message)")
        }
      }
      Section {
        HStack {
          Button("Cancel", role: .cancel) {
            cancel()
          }
          Spacer()
          Button {
            Task { await submit() }
          } label: {
            Label("Create", systemImage: "plus.circle.fill")
              .scaledFont(.body.weight(.semibold))
          }
          .frame(minHeight: metrics.submitButtonMinHeight)
          .keyboardShortcut(.defaultAction)
        }
      }
    }
    .formStyle(.grouped)
    .padding(metrics.formPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .task {
      if focusedField == nil {
        focusedField = .name
      }
      await loadAgentCapabilitiesIfNeeded()
    }
  }

  private func updateDraft(
    title: String? = nil,
    prompt: String? = nil,
    runtime: String? = nil,
    taskSeverity: TaskSeverity? = nil
  ) {
    var next = draft
    if let title {
      next.title = title
    }
    if let prompt {
      next.prompt = prompt
    }
    if let runtime {
      next.runtime = runtime
    }
    if let taskSeverity {
      next.taskSeverity = taskSeverity
    }
    clearValidationIfNeeded(title: title, runtime: runtime)
    state.updateCreateDraft(next)
  }

  @MainActor
  private func submit() async {
    if let validationResult = SessionWindowCreateFormValidation.result(
      for: draft,
      capabilityOptions: activeAgentCapabilityOptions
    ) {
      self.validationResult = validationResult
      focusValidationField(validationResult.field)
      return
    }
    let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    validationResult = nil
    switch draft.kind {
    case .agent:
      await createAgent(named: name)
    case .task:
      await createTask(named: name)
    case .decision:
      await createDecision(summary: name)
    }
  }

  private func cancel() {
    validationResult = nil
    state.cancelCreateDraft(draft.kind)
  }

  @MainActor
  private func createAgent(named name: String) async {
    switch SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: activeAgentCapabilityOptions
    ) {
    case .tui(let runtime):
      guard
        let created = await store.startAgentTuiSnapshot(
          runtime: runtime,
          name: name,
          prompt: draft.prompt,
          rows: 32,
          cols: 120,
          sessionID: draft.sessionID
        )
      else {
        return
      }
      state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
      state.selectAgent(created.agentId)
    case .acp(let descriptorID):
      let capabilities = capabilities(for: .acp(descriptorID))
      guard
        let created = await store.startAcpAgent(
          agentID: descriptorID,
          capabilities: capabilities,
          name: name,
          prompt: draft.prompt,
          sessionID: draft.sessionID
        )
      else {
        return
      }
      state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
      state.selectAgent(created.agentId)
    }
  }

  @MainActor
  private func loadAgentCapabilitiesIfNeeded() async {
    guard draft.kind == .agent else { return }
    guard agentCapabilityOptions.isEmpty else { return }
    isLoadingAgentCapabilities = true
    let options = await SessionWindowCreateFormCatalogs.loadAgentOptions(store: store)
    agentCapabilityOptions = options
    isLoadingAgentCapabilities = false
    let normalized = SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: options
    )
    if normalized.storageKey != draft.launchSelection.storageKey {
      updateDraft(runtime: normalized.storageKey)
    }
  }

  private func capabilities(for selection: AgentLaunchSelection) -> [String] {
    guard
      let option = activeAgentCapabilityOptions.first(where: { option in
        option.transportChoices.contains { $0.id == selection }
      })
    else {
      return []
    }
    return option.transportChoice(for: selection).capabilities
  }

  @MainActor
  private func createTask(named name: String) async {
    let context = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let success = await store.createTask(
      title: name,
      context: context.isEmpty ? nil : context,
      severity: draft.taskSeverity,
      sessionID: draft.sessionID
    )
    guard success else { return }
    state.updateCreateDraft(SessionCreateDraft(kind: .task, sessionID: draft.sessionID))
    state.selectRoute(.tasks)
  }

  @MainActor
  private func createDecision(summary: String) async {
    guard let decisionStore = store.supervisorDecisionStore else {
      validationResult = .init(message: "Decision store is unavailable.", field: .form)
      return
    }
    let id = "manual-\(UUID().uuidString)"
    let decision = DecisionDraft(
      id: id,
      severity: .needsUser,
      ruleID: "manual-session-window",
      sessionID: draft.sessionID,
      agentID: nil,
      taskID: nil,
      summary: summary,
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
    do {
      try await decisionStore.insert(decision)
      state.updateCreateDraft(SessionCreateDraft(kind: .decision, sessionID: draft.sessionID))
      state.selectDecision(id)
    } catch {
      validationResult = .init(message: error.localizedDescription, field: .form)
    }
  }

  private func validationMessage(
    for field: SessionWindowCreateFormValidationField
  ) -> String? {
    guard validationResult?.field == field else { return nil }
    return validationResult?.message
  }

  private func clearValidationIfNeeded(title: String?, runtime: String?) {
    switch validationResult?.field {
    case .name where title != nil:
      validationResult = nil
    case .capability where runtime != nil:
      validationResult = nil
    case .form, .name, .capability, nil:
      break
    }
  }

  private func focusValidationField(_ field: SessionWindowCreateFormValidationField) {
    if field == .name {
      focusedField = .name
    }
  }
}

private enum SessionWindowCreateFormField: Hashable {
  case name
  case prompt
}

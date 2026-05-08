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
  @State private var validationMessage = ""
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
          isLoading: isLoadingAgentCapabilities
        )
      }
      if !validationMessage.isEmpty {
        Section {
          Text(validationMessage)
            .scaledFont(.callout)
            .foregroundStyle(.red)
            .accessibilityLabel(validationMessage)
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
          .keyboardShortcut("n", modifiers: [.command])
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
    runtime: String? = nil
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
    state.updateCreateDraft(next)
  }

  @MainActor
  private func submit() async {
    if let message = SessionWindowCreateFormValidation.message(
      for: draft,
      capabilityOptions: activeAgentCapabilityOptions
    ) {
      validationMessage = message
      return
    }
    let name = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
    validationMessage = ""
    switch draft.kind {
    case .agent:
      await createAgent(named: name)
    case .task:
      store.requestCreateTaskSheet()
      state.selectRoute(.tasks)
    case .decision:
      await createDecision(summary: name)
    }
  }

  private func cancel() {
    validationMessage = ""
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
  private func createDecision(summary: String) async {
    guard let decisionStore = store.supervisorDecisionStore else {
      validationMessage = "Decision store is unavailable."
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
      validationMessage = error.localizedDescription
    }
  }
}

private enum SessionWindowCreateFormField: Hashable {
  case name
  case prompt
}

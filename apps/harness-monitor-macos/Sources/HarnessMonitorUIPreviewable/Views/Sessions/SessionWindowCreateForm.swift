import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateFormMetrics: Equatable {
  let formPadding: CGFloat
  let promptMinHeight: CGFloat
  let submitButtonMinHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(max(fontScale, 0.85), 1.8)
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

  private var runtime: Binding<String> {
    Binding(
      get: { draft.runtime },
      set: { updateDraft(runtime: $0) }
    )
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
        if draft.kind == .agent {
          Picker("Runtime", selection: runtime) {
            ForEach(AgentTuiRuntime.allCases) { runtime in
              Text(runtime.title).tag(runtime.rawValue)
            }
          }
          .scaledFont(.body)
        }
        TextEditor(text: prompt)
          .scaledFont(.body)
          .frame(minHeight: metrics.promptMinHeight)
          .focused($focusedField, equals: .prompt)
          .accessibilityLabel("Prompt")
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
    if let message = SessionWindowCreateFormValidation.message(for: draft) {
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
    let runtime = AgentTuiRuntime(rawValue: draft.runtime) ?? .codex
    let created = await store.startAgentTui(
      runtime: runtime,
      name: name,
      prompt: draft.prompt,
      rows: 32,
      cols: 120,
      sessionID: draft.sessionID
    )
    if created {
      state.updateCreateDraft(SessionCreateDraft(kind: .agent, sessionID: draft.sessionID))
      state.selectRoute(.agents)
    }
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

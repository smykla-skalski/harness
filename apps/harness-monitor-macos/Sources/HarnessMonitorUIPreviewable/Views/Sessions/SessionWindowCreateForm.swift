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
  @State var validationResult: SessionWindowCreateFormValidationResult?
  @State var agentCapabilityOptions: [AgentCapabilityOption] = []
  @State var isLoadingAgentCapabilities = false
  @FocusState var focusedField: SessionWindowCreateFormField?

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

  var activeAgentCapabilityOptions: [AgentCapabilityOption] {
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

  func updateDraft(
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

  private func cancel() {
    validationResult = nil
    state.cancelCreateDraft(draft.kind)
  }
}

enum SessionWindowCreateFormField: Hashable {
  case name
  case prompt
}

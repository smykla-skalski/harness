import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

struct WatchCommandComposerView: View {
  @State private var model: CommandFormModel
  @Environment(\.dismiss) private var dismiss
  @State private var confirmationPresented = false
  let store: MirrorStore

  init(store: MirrorStore, initialStationID: String = "", initialKind: MobileCommandKind = .refresh) {
    self.store = store
    _model = State(
      wrappedValue: CommandFormModel(
        store: store,
        profile: .watch,
        initialStationID: initialStationID,
        initialKind: initialKind
      )
    )
  }

  var body: some View {
    Form {
      Section {
        Picker("Station", selection: $model.stationID) {
          ForEach(store.snapshot.stations) { station in
            Text(station.displayName).tag(station.id)
          }
        }
        Picker("Command", selection: $model.kind) {
          ForEach(MobileCommandKind.allCases, id: \.self) { commandKind in
            Text(commandKind.title).tag(commandKind)
          }
        }
      }

      detailsSection

      Section {
        Text(confirmationText)
          .font(.caption)
        if let validationMessage {
          Label(validationMessage, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        Button {
          confirmationPresented = true
        } label: {
          Label("Review", systemImage: "checkmark.seal")
        }
        .disabled(!model.canSubmit)
      }
    }
    .navigationTitle("New Command")
    .task {
      model.seedStationIfNeeded()
    }
    .onChange(of: model.stationID) { _, _ in
      model.clearForeignSelections()
    }
    .onChange(of: model.kind) { _, _ in
      model.seedDefaultsForKind()
    }
    .confirmationDialog(
      confirmationText,
      isPresented: $confirmationPresented,
      titleVisibility: .visible
    ) {
      Button(model.submitting ? "Queuing..." : "Confirm") {
        Task { await submit() }
      }
      .disabled(model.submitting)
      Button("Cancel", role: .cancel) {}
    }
  }

  @ViewBuilder private var detailsSection: some View {
    Section {
      switch model.kind {
      case .acpPermissionDecision:
        agentIDField
        TextField("Batch ID", text: $model.batchID)
        Picker("Decision", selection: $model.acpDecision) {
          Text("Approve").tag("approve_all")
          Text("Deny").tag("deny_all")
          Text("Some").tag("approve_some")
        }
      case .taskBoardDispatch:
        taskIDField(required: false)
        Picker("Status", selection: $model.taskStatus) {
          Text("Any").tag("")
          Text("Ready").tag("todo")
          Text("Progress").tag("in_progress")
          Text("Review").tag("in_review")
          Text("Done").tag("done")
          Text("Blocked").tag("blocked")
        }
      case .taskBoardPlanApproval:
        taskIDField(required: true)
      case .agentStart:
        sessionIDField
        TextField("Agent", text: $model.agent)
        Picker("Role", selection: $model.role) {
          Text("Worker").tag("worker")
          Text("Reviewer").tag("reviewer")
          Text("Improver").tag("improver")
          Text("Leader").tag("leader")
        }
        promptFields(title: "Prompt")
      case .agentStop:
        agentIDField
      case .agentPrompt:
        agentIDField
        promptFields(title: "Prompt")
      case .pullRequestApprove, .pullRequestRerunChecks:
        reviewFields
      case .pullRequestLabel:
        reviewFields
        TextField("Label", text: $model.label)
      case .pullRequestMerge:
        reviewFields
        Picker("Method", selection: $model.mergeMethod) {
          Text("Squash").tag("squash")
          Text("Merge").tag("merge")
          Text("Rebase").tag("rebase")
        }
        TextField("Audit reason", text: $model.auditReason)
      case .refresh:
        Picker("Scope", selection: $model.refreshScope) {
          Text("Mirror").tag("mobileMirror")
          Text("Health").tag("health")
          Text("Reviews").tag("reviews")
          Text("Board").tag("taskBoard")
          Text("Tasks").tag("sessionTasks")
        }
        if model.refreshScope == "sessionTasks" {
          sessionIDField
          taskIDField(required: false)
        } else if model.refreshScope == "reviews" {
          reviewFields
        }
      }
    }
  }

  private var sessionIDField: some View {
    Group {
      if !model.sessionsForStation.isEmpty {
        Picker("Session", selection: $model.sessionID) {
          Text("Manual").tag("")
          ForEach(model.sessionsForStation) { session in
            Text(session.title).tag(session.id)
          }
        }
      }
      TextField("Session ID", text: $model.sessionID)
    }
  }

  private var agentIDField: some View {
    TextField("Agent ID", text: $model.agentID)
  }

  private func taskIDField(required: Bool) -> some View {
    Group {
      if !model.taskBoardItemsForStation.isEmpty {
        Picker("Task", selection: $model.taskID) {
          Text("Manual").tag("")
          ForEach(model.taskBoardItemsForStation) { item in
            Text(item.title).tag(item.id)
          }
        }
      }
      TextField(required ? "Task ID" : "Task ID optional", text: $model.taskID)
    }
  }

  private func promptFields(title: LocalizedStringKey) -> some View {
    Group {
      Picker("Preset", selection: $model.promptPreset) {
        Text("Continue").tag("continue")
        Text("Summarize").tag("summarize")
        Text("Run tests").tag("tests")
        Text("Handoff").tag("handoff")
        Text("Dictate").tag("custom")
      }
      TextField(title, text: $model.prompt)
    }
  }

  private var reviewFields: some View {
    Group {
      if !model.reviewsForStation.isEmpty {
        Picker("PR", selection: $model.reviewID) {
          Text("Manual").tag("")
          ForEach(model.reviewsForStation) { review in
            Text(verbatim: "#\(review.number)").tag(review.id)
          }
        }
      }
      TextField("PR ID", text: $model.reviewID)
      TextField("Repo", text: $model.repository)
      TextField("Number", text: $model.reviewNumber)
    }
  }
}

extension WatchCommandComposerView {
  fileprivate var validationMessage: String? {
    switch model.validationError {
    case .invalidDraft(let message):
      message
    case .stationNotPaired:
      String(localized: "Station is not paired")
    case nil:
      nil
    }
  }

  fileprivate var confirmationText: String {
    switch model.kind {
    case .acpPermissionDecision:
      let decision =
        model.acpDecision == "deny_all"
        ? String(localized: "Deny") : String(localized: "Approve")
      return String(localized: "\(decision) permission for \(agentDisplay)")
    case .taskBoardDispatch:
      return String(localized: "Dispatch task board work")
    case .taskBoardPlanApproval:
      return String(localized: "Approve plan \(taskDisplay)")
    case .agentStart:
      let agent = model.agent.trimmedDisplay(fallback: String(localized: "agent"))
      return String(localized: "Start \(agent) in \(sessionDisplay)")
    case .agentStop:
      return String(localized: "Stop \(agentDisplay)")
    case .agentPrompt:
      return String(localized: "Prompt \(agentDisplay)")
    case .pullRequestApprove:
      return String(localized: "Approve \(reviewDisplay)")
    case .pullRequestLabel:
      return String(localized: "Label \(reviewDisplay)")
    case .pullRequestRerunChecks:
      return String(localized: "Rerun checks for \(reviewDisplay)")
    case .pullRequestMerge:
      return String(localized: "Merge \(reviewDisplay) with \(model.mergeMethod)")
    case .refresh:
      return String(localized: "Refresh \(refreshScopeDisplay)")
    }
  }

  fileprivate var agentDisplay: String {
    model.agentID.trimmedDisplay(fallback: String(localized: "agent"))
  }

  fileprivate var taskDisplay: String {
    model.taskID.trimmedDisplay(fallback: String(localized: "task"))
  }

  fileprivate var sessionDisplay: String {
    model.sessionID.trimmedDisplay(fallback: String(localized: "session"))
  }

  fileprivate var reviewDisplay: String {
    if let review = model.selectedReview {
      return "#\(review.number)"
    }
    if !model.reviewNumber.trimmedForWatchCommand.isEmpty {
      return "#\(model.reviewNumber.trimmedForWatchCommand)"
    }
    return String(localized: "PR")
  }

  fileprivate var refreshScopeDisplay: String {
    switch model.refreshScope {
    case "mobileMirror": String(localized: "mirror")
    case "reviews": String(localized: "reviews")
    case "taskBoard": String(localized: "task board")
    case "sessionTasks": String(localized: "session tasks")
    default: String(localized: "health")
    }
  }

  fileprivate func submit() async {
    model.submitting = true
    defer { model.submitting = false }
    await store.queueCommand(model.makeDraft(confirmationText: confirmationText))
    dismiss()
  }
}

extension String {
  fileprivate var trimmedForWatchCommand: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate func trimmedDisplay(fallback: String) -> String {
    let value = trimmedForWatchCommand
    return value.isEmpty ? fallback : value
  }
}

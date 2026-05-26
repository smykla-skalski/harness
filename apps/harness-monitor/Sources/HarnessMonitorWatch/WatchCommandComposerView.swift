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

  private func promptFields(title: String) -> some View {
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
      "Station is not paired."
    case nil:
      nil
    }
  }

  fileprivate var confirmationText: String {
    switch model.kind {
    case .acpPermissionDecision:
      "\(model.acpDecision == "deny_all" ? "Deny" : "Approve") permission for \(agentDisplay)."
    case .taskBoardDispatch:
      "Dispatch task board work."
    case .taskBoardPlanApproval:
      "Approve plan \(taskDisplay)."
    case .agentStart:
      "Start \(model.agent.trimmedDisplay(fallback: "agent")) in \(sessionDisplay)."
    case .agentStop:
      "Stop \(agentDisplay)."
    case .agentPrompt:
      "Prompt \(agentDisplay)."
    case .pullRequestApprove:
      "Approve \(reviewDisplay)."
    case .pullRequestLabel:
      "Label \(reviewDisplay)."
    case .pullRequestRerunChecks:
      "Rerun checks for \(reviewDisplay)."
    case .pullRequestMerge:
      "Merge \(reviewDisplay) with \(model.mergeMethod)."
    case .refresh:
      "Refresh \(refreshScopeDisplay)."
    }
  }

  fileprivate var agentDisplay: String {
    model.agentID.trimmedDisplay(fallback: "agent")
  }

  fileprivate var taskDisplay: String {
    model.taskID.trimmedDisplay(fallback: "task")
  }

  fileprivate var sessionDisplay: String {
    model.sessionID.trimmedDisplay(fallback: "session")
  }

  fileprivate var reviewDisplay: String {
    if let review = model.selectedReview {
      return "#\(review.number)"
    }
    if !model.reviewNumber.trimmedForWatchCommand.isEmpty {
      return "#\(model.reviewNumber.trimmedForWatchCommand)"
    }
    return "PR"
  }

  fileprivate var refreshScopeDisplay: String {
    switch model.refreshScope {
    case "mobileMirror": "mirror"
    case "reviews": "reviews"
    case "taskBoard": "task board"
    case "sessionTasks": "session tasks"
    default: "health"
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

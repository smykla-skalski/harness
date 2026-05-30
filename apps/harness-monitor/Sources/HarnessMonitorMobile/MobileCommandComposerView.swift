import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

struct MobileCommandComposerView: View {
  @State private var model: CommandFormModel
  @Environment(\.dismiss)
  private var dismiss
  let store: MirrorStore

  init(
    store: MirrorStore,
    initialStationID: String = "",
    initialKind: MobileCommandKind = .refresh,
    initialSessionID: String = "",
    initialAgentID: String = "",
    initialTaskID: String = "",
    initialPrompt: String = ""
  ) {
    self.store = store
    _model = State(
      wrappedValue: CommandFormModel(
        store: store,
        profile: .phone,
        initialStationID: initialStationID,
        initialKind: initialKind,
        initialSessionID: initialSessionID,
        initialAgentID: initialAgentID,
        initialTaskID: initialTaskID,
        initialPrompt: initialPrompt
      )
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Command") {
          stationPicker
          Picker("Family", selection: $model.kind) {
            ForEach(MobileCommandKind.allCases, id: \.self) { commandKind in
              Text(commandKind.title).tag(commandKind)
            }
          }
        }

        detailsSection

        Section("Confirmation") {
          Text(confirmationText)
            .font(.subheadline)
          if model.kind == .pullRequestMerge {
            TextField("Audit reason", text: $model.auditReason, axis: .vertical)
              .lineLimit(2...4)
          }
          if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      }
      .navigationTitle("New Command")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await submit() }
          } label: {
            if model.submitting {
              ProgressView()
            } else {
              Label("Queue", systemImage: "checkmark.seal")
            }
          }
          .disabled(!model.canSubmit)
        }
      }
      .task {
        model.seedStationIfNeeded()
      }
      .onChange(of: model.stationID) { _, _ in
        model.clearForeignSelections()
      }
      .onChange(of: model.kind) { _, _ in
        model.seedDefaultsForKind()
      }
    }
  }

  private var stationPicker: some View {
    Picker("Station", selection: $model.stationID) {
      ForEach(store.snapshot.stations) { station in
        Text(station.displayName).tag(station.id)
      }
    }
    .disabled(store.snapshot.stations.isEmpty)
  }

  @ViewBuilder private var detailsSection: some View {
    Section("Details") {
      switch model.kind {
      case .acpPermissionDecision:
        agentIDField
        TextField("Batch ID", text: $model.batchID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Picker("Decision", selection: $model.acpDecision) {
          Text("Approve all").tag("approve_all")
          Text("Deny all").tag("deny_all")
          Text("Approve some").tag("approve_some")
        }
      case .taskBoardDispatch:
        taskIDField(required: false)
        Picker("Status", selection: $model.taskStatus) {
          Text("Leave unchanged").tag("")
          Text("Ready").tag("todo")
          Text("In progress").tag("in_progress")
          Text("In review").tag("in_review")
          Text("Done").tag("done")
          Text("Blocked").tag("blocked")
        }
        Toggle("Dry run", isOn: $model.dryRun)
      case .taskBoardPlanApproval:
        taskIDField(required: true)
      case .agentStart:
        sessionIDField
        TextField("Agent", text: $model.agent)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Picker("Role", selection: $model.role) {
          Text("Leader").tag("leader")
          Text("Worker").tag("worker")
          Text("Reviewer").tag("reviewer")
          Text("Improver").tag("improver")
          Text("Observer").tag("observer")
        }
        TextField("Initial prompt", text: $model.prompt, axis: .vertical)
          .lineLimit(2...5)
      case .agentStop:
        agentIDField
      case .agentPrompt:
        agentIDField
        TextField("Prompt", text: $model.prompt, axis: .vertical)
          .lineLimit(3...6)
      case .pullRequestApprove, .pullRequestRerunChecks:
        reviewFields
      case .pullRequestLabel:
        reviewFields
        TextField("Label", text: $model.label)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      case .pullRequestMerge:
        reviewFields
        Picker("Method", selection: $model.mergeMethod) {
          Text("Squash").tag("squash")
          Text("Merge").tag("merge")
          Text("Rebase").tag("rebase")
        }
      case .refresh:
        Picker("Scope", selection: $model.refreshScope) {
          Text("Mirror").tag("mobileMirror")
          Text("Station health").tag("health")
          Text("Reviews").tag("reviews")
          Text("Task board").tag("taskBoard")
          Text("Session tasks").tag("sessionTasks")
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
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private var agentIDField: some View {
    TextField("Agent ID", text: $model.agentID)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
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
      TextField(required ? "Task ID" : "Task ID (optional)", text: $model.taskID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private var reviewFields: some View {
    Group {
      if !model.reviewsForStation.isEmpty {
        Picker("Pull Request", selection: $model.reviewID) {
          Text("Manual").tag("")
          ForEach(model.reviewsForStation) { review in
            Text(verbatim: "#\(review.number) \(review.title)").tag(review.id)
          }
        }
      }
      TextField("Pull request ID", text: $model.reviewID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Repository", text: $model.repository)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Number", text: $model.reviewNumber)
        .keyboardType(.numberPad)
    }
  }
}

extension MobileCommandComposerView {
  fileprivate var validationMessage: String? {
    switch model.validationError {
    case .invalidDraft(let message):
      return message
    case .stationNotPaired:
      return String(localized: "This station is not paired for live commands")
    case nil:
      return nil
    }
  }

  fileprivate var confirmationText: String {
    let stationName =
      store.snapshot.station(id: model.effectiveStationID)?.displayName
      ?? String(localized: "selected station")
    switch model.kind {
    case .acpPermissionDecision:
      return String(localized: "\(acpDecisionTitle) ACP permission for \(agentIDOrFallback)")
    case .taskBoardDispatch:
      return String(localized: "Dispatch task board work on \(stationName)")
    case .taskBoardPlanApproval:
      return String(localized: "Approve task board plan \(taskIDOrFallback)")
    case .agentStart:
      return String(localized: "Start \(model.agent) as \(model.role) in \(sessionIDOrFallback)")
    case .agentStop:
      return String(localized: "Stop \(agentIDOrFallback)")
    case .agentPrompt:
      return String(localized: "Send prompt to \(agentIDOrFallback)")
    case .pullRequestApprove:
      return String(localized: "Approve \(reviewTitleOrFallback)")
    case .pullRequestLabel:
      return String(localized: "Apply label \(labelOrFallback) to \(reviewTitleOrFallback)")
    case .pullRequestRerunChecks:
      return String(localized: "Rerun checks for \(reviewTitleOrFallback)")
    case .pullRequestMerge:
      return String(localized: "Merge \(reviewTitleOrFallback) with \(model.mergeMethod)")
    case .refresh:
      return String(localized: "Refresh \(refreshScopeTitle) on \(stationName)")
    }
  }

  fileprivate var acpDecisionTitle: String {
    switch model.acpDecision {
    case "approve_all": String(localized: "Approve")
    case "deny_all": String(localized: "Deny")
    case "approve_some": String(localized: "Partially approve")
    default: model.acpDecision
    }
  }

  fileprivate var agentIDOrFallback: String {
    model.agentID.trimmedForCommandDisplay(ifEmpty: String(localized: "selected agent"))
  }

  fileprivate var taskIDOrFallback: String {
    model.taskID.trimmedForCommandDisplay(ifEmpty: String(localized: "selected task"))
  }

  fileprivate var sessionIDOrFallback: String {
    model.sessionID.trimmedForCommandDisplay(ifEmpty: String(localized: "selected session"))
  }

  fileprivate var labelOrFallback: String {
    model.label.trimmedForCommandDisplay(ifEmpty: String(localized: "label"))
  }

  fileprivate var refreshScopeTitle: String {
    switch model.refreshScope {
    case "mobileMirror": String(localized: "mobile mirror")
    case "reviews": String(localized: "reviews")
    case "taskBoard": String(localized: "task board")
    case "sessionTasks": String(localized: "session tasks")
    default: String(localized: "station health")
    }
  }

  fileprivate var reviewTitleOrFallback: String {
    if let review = model.selectedReview {
      return "#\(review.number)"
    }
    if !model.repository.trimmedForCommand.isEmpty, !model.reviewNumber.trimmedForCommand.isEmpty {
      return "#\(model.reviewNumber.trimmedForCommand)"
    }
    return String(localized: "selected PR")
  }

  fileprivate func submit() async {
    model.submitting = true
    defer { model.submitting = false }
    await store.queueCommand(model.makeDraft(confirmationText: confirmationText))
    dismiss()
  }
}

extension String {
  fileprivate var trimmedForCommand: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate func trimmedForCommandDisplay(ifEmpty fallback: String) -> String {
    let value = trimmedForCommand
    return value.isEmpty ? fallback : value
  }
}

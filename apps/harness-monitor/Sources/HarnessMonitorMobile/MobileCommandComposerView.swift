import HarnessMonitorCore
import SwiftUI

struct MobileCommandComposerView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  @Environment(\.dismiss)
  private var dismiss

  @State private var stationID: String
  @State private var kind: MobileCommandKind
  @State private var sessionID = ""
  @State private var agentID = ""
  @State private var taskID = ""
  @State private var reviewID = ""
  @State private var repository = ""
  @State private var reviewNumber = ""
  @State private var batchID = ""
  @State private var acpDecision = "approve_all"
  @State private var taskStatus = ""
  @State private var dryRun = false
  @State private var agent = "codex"
  @State private var role = "worker"
  @State private var prompt = ""
  @State private var label = ""
  @State private var mergeMethod = "squash"
  @State private var refreshScope = "health"
  @State private var auditReason = ""
  @State private var submitting = false

  init(
    initialStationID: String = "",
    initialKind: MobileCommandKind = .refresh,
    initialSessionID: String = "",
    initialAgentID: String = "",
    initialTaskID: String = "",
    initialPrompt: String = ""
  ) {
    _stationID = State(initialValue: initialStationID)
    _kind = State(initialValue: initialKind)
    _sessionID = State(initialValue: initialSessionID)
    _agentID = State(initialValue: initialAgentID)
    _taskID = State(initialValue: initialTaskID)
    _prompt = State(initialValue: initialPrompt)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Command") {
          stationPicker
          Picker("Family", selection: $kind) {
            ForEach(MobileCommandKind.allCases, id: \.self) { commandKind in
              Text(commandKind.title).tag(commandKind)
            }
          }
        }

        detailsSection

        Section("Confirmation") {
          Text(confirmationText)
            .font(.subheadline)
          if kind == .pullRequestMerge {
            TextField("Audit reason", text: $auditReason, axis: .vertical)
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
            if submitting {
              ProgressView()
            } else {
              Label("Queue", systemImage: "checkmark.seal")
            }
          }
          .disabled(!canSubmit)
        }
      }
      .task {
        seedStationIfNeeded()
      }
      .onChange(of: stationID) { _, _ in
        clearForeignSelections()
      }
      .onChange(of: kind) { _, _ in
        seedDefaultsForKind()
      }
    }
  }

  private var stationPicker: some View {
    Picker("Station", selection: $stationID) {
      ForEach(store.snapshot.stations) { station in
        Text(station.displayName).tag(station.id)
      }
    }
    .disabled(store.snapshot.stations.isEmpty)
  }

  @ViewBuilder private var detailsSection: some View {
    Section("Details") {
      switch kind {
      case .acpPermissionDecision:
        agentIDField
        TextField("Batch ID", text: $batchID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Picker("Decision", selection: $acpDecision) {
          Text("Approve all").tag("approve_all")
          Text("Deny all").tag("deny_all")
          Text("Approve some").tag("approve_some")
        }
      case .taskBoardDispatch:
        taskIDField(required: false)
        Picker("Status", selection: $taskStatus) {
          Text("Leave unchanged").tag("")
          Text("Ready").tag("todo")
          Text("In progress").tag("in_progress")
          Text("In review").tag("in_review")
          Text("Done").tag("done")
          Text("Blocked").tag("blocked")
        }
        Toggle("Dry run", isOn: $dryRun)
      case .taskBoardPlanApproval:
        taskIDField(required: true)
      case .agentStart:
        sessionIDField
        TextField("Agent", text: $agent)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Picker("Role", selection: $role) {
          Text("Leader").tag("leader")
          Text("Worker").tag("worker")
          Text("Reviewer").tag("reviewer")
          Text("Improver").tag("improver")
          Text("Observer").tag("observer")
        }
        TextField("Initial prompt", text: $prompt, axis: .vertical)
          .lineLimit(2...5)
      case .agentStop:
        agentIDField
      case .agentPrompt:
        agentIDField
        TextField("Prompt", text: $prompt, axis: .vertical)
          .lineLimit(3...6)
      case .pullRequestApprove, .pullRequestRerunChecks:
        reviewFields
      case .pullRequestLabel:
        reviewFields
        TextField("Label", text: $label)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      case .pullRequestMerge:
        reviewFields
        Picker("Method", selection: $mergeMethod) {
          Text("Squash").tag("squash")
          Text("Merge").tag("merge")
          Text("Rebase").tag("rebase")
        }
      case .refresh:
        Picker("Scope", selection: $refreshScope) {
          Text("Mirror").tag("mobileMirror")
          Text("Station health").tag("health")
          Text("Reviews").tag("reviews")
          Text("Task board").tag("taskBoard")
          Text("Session tasks").tag("sessionTasks")
        }
        if refreshScope == "sessionTasks" {
          sessionIDField
          taskIDField(required: false)
        } else if refreshScope == "reviews" {
          reviewFields
        }
      }
    }
  }

  private var sessionIDField: some View {
    Group {
      if !sessionsForStation.isEmpty {
        Picker("Session", selection: $sessionID) {
          Text("Manual").tag("")
          ForEach(sessionsForStation) { session in
            Text(session.title).tag(session.id)
          }
        }
      }
      TextField("Session ID", text: $sessionID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private var agentIDField: some View {
    TextField("Agent ID", text: $agentID)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
  }

  private func taskIDField(required: Bool) -> some View {
    Group {
      if !taskBoardItemsForStation.isEmpty {
        Picker("Task", selection: $taskID) {
          Text("Manual").tag("")
          ForEach(taskBoardItemsForStation) { item in
            Text(item.title).tag(item.id)
          }
        }
      }
      TextField(required ? "Task ID" : "Task ID (optional)", text: $taskID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private var reviewFields: some View {
    Group {
      if !reviewsForStation.isEmpty {
        Picker("Pull Request", selection: $reviewID) {
          Text("Manual").tag("")
          ForEach(reviewsForStation) { review in
            Text(verbatim: "#\(review.number) \(review.title)").tag(review.id)
          }
        }
      }
      TextField("Pull request ID", text: $reviewID)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Repository", text: $repository)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Number", text: $reviewNumber)
        .keyboardType(.numberPad)
    }
  }

  private var effectiveStationID: String {
    if !stationID.isEmpty {
      return stationID
    }
    return store.snapshot.stations.first?.id ?? ""
  }

  private var sessionsForStation: [MobileSessionSummary] {
    store.snapshot.sessions
      .filter { $0.stationID == effectiveStationID }
      .sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  private var reviewsForStation: [MobileReviewSummary] {
    store.snapshot.reviews
      .filter { $0.stationID == effectiveStationID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private var taskBoardItemsForStation: [MobileTaskBoardSummary] {
    store.snapshot.taskBoardItems(for: effectiveStationID)
  }

  private var validationMessage: String? {
    do {
      try makeDraft().validate()
      if !store.canQueueCommand(stationID: effectiveStationID) {
        return "This station is not paired for live commands."
      }
      return nil
    } catch {
      return String(describing: error)
    }
  }

  private var canSubmit: Bool {
    !submitting && validationMessage == nil
  }

  private var confirmationText: String {
    let stationName =
      store.snapshot.station(id: effectiveStationID)?.displayName
      ?? "selected station"
    switch kind {
    case .acpPermissionDecision:
      return "\(acpDecisionTitle) ACP permission for \(agentIDOrFallback)."
    case .taskBoardDispatch:
      return "Dispatch task board work on \(stationName)."
    case .taskBoardPlanApproval:
      return "Approve task board plan \(taskIDOrFallback)."
    case .agentStart:
      return "Start \(agent) as \(role) in \(sessionIDOrFallback)."
    case .agentStop:
      return "Stop \(agentIDOrFallback)."
    case .agentPrompt:
      return "Send prompt to \(agentIDOrFallback)."
    case .pullRequestApprove:
      return "Approve \(reviewTitleOrFallback)."
    case .pullRequestLabel:
      return "Apply label \(labelOrFallback) to \(reviewTitleOrFallback)."
    case .pullRequestRerunChecks:
      return "Rerun checks for \(reviewTitleOrFallback)."
    case .pullRequestMerge:
      return "Merge \(reviewTitleOrFallback) with \(mergeMethod)."
    case .refresh:
      return "Refresh \(refreshScopeTitle) on \(stationName)."
    }
  }

  private var acpDecisionTitle: String {
    switch acpDecision {
    case "approve_all": "Approve"
    case "deny_all": "Deny"
    case "approve_some": "Partially approve"
    default: acpDecision
    }
  }

  private var agentIDOrFallback: String {
    agentID.trimmedForCommandDisplay(ifEmpty: "selected agent")
  }

  private var taskIDOrFallback: String {
    taskID.trimmedForCommandDisplay(ifEmpty: "selected task")
  }

  private var sessionIDOrFallback: String {
    sessionID.trimmedForCommandDisplay(ifEmpty: "selected session")
  }

  private var labelOrFallback: String {
    label.trimmedForCommandDisplay(ifEmpty: "label")
  }

  private var refreshScopeTitle: String {
    switch refreshScope {
    case "mobileMirror": "mobile mirror"
    case "reviews": "reviews"
    case "taskBoard": "task board"
    case "sessionTasks": "session tasks"
    default: "station health"
    }
  }

  private var reviewTitleOrFallback: String {
    if let review = selectedReview {
      return "#\(review.number)"
    }
    if !repository.trimmedForCommand.isEmpty, !reviewNumber.trimmedForCommand.isEmpty {
      return "#\(reviewNumber.trimmedForCommand)"
    }
    return "selected PR"
  }

  private func makeDraft() -> MobileCommandDraft {
    if let reviewDraft = selectedReviewDraft {
      return reviewDraft
    }
    if let taskDraft = selectedTaskDraft {
      return taskDraft
    }
    let target = MobileCommandTarget(
      stationID: effectiveStationID,
      sessionID: sessionID.trimmedCommandValue,
      agentID: agentID.trimmedCommandValue,
      reviewID: reviewID.trimmedCommandValue,
      taskID: taskID.trimmedCommandValue,
      targetRevision: store.snapshot.revision
    )
    return MobileCommandDraft(
      kind: kind,
      confirmationText: confirmationText,
      auditReason: auditReason.trimmedCommandValue,
      target: target,
      payload: payload
    )
  }

  private var selectedReview: MobileReviewSummary? {
    store.snapshot.reviews.first { $0.id == reviewID && $0.stationID == effectiveStationID }
  }

  private var selectedTask: MobileTaskBoardSummary? {
    store.snapshot.taskBoardItems.first { $0.id == taskID && $0.stationID == effectiveStationID }
  }

  private var selectedReviewDraft: MobileCommandDraft? {
    guard let review = selectedReview else {
      return nil
    }
    switch kind {
    case .pullRequestApprove, .pullRequestLabel, .pullRequestRerunChecks, .pullRequestMerge:
      return review.commandDraft(
        kind: kind,
        targetRevision: store.snapshot.revision,
        label: label,
        mergeMethod: mergeMethod,
        auditReason: auditReason.trimmedCommandValue
      )
    default:
      return nil
    }
  }

  private var selectedTaskDraft: MobileCommandDraft? {
    guard let task = selectedTask else {
      return nil
    }
    switch kind {
    case .taskBoardDispatch:
      var draft = task.commandDraft(
        kind: .taskBoardDispatch,
        targetRevision: store.snapshot.revision,
        status: taskStatus
      )
      draft.payload["dryRun"] = dryRun ? "true" : "false"
      return draft
    case .taskBoardPlanApproval:
      return task.commandDraft(
        kind: .taskBoardPlanApproval,
        targetRevision: store.snapshot.revision
      )
    default:
      return nil
    }
  }

  private var payload: [String: String] {
    var payload: [String: String] = [:]
    switch kind {
    case .acpPermissionDecision:
      payload["batchID"] = batchID
      payload["decision"] = acpDecision
    case .taskBoardDispatch:
      payload["status"] = taskStatus
      payload["dryRun"] = dryRun ? "true" : "false"
    case .taskBoardPlanApproval, .agentStop, .pullRequestApprove, .pullRequestRerunChecks:
      break
    case .agentStart:
      payload["agent"] = agent
      payload["role"] = role
      payload["prompt"] = prompt
    case .agentPrompt:
      payload["prompt"] = prompt
    case .pullRequestLabel:
      payload["label"] = label
      addManualReviewPayload(to: &payload)
    case .pullRequestMerge:
      payload["method"] = mergeMethod
      addManualReviewPayload(to: &payload)
    case .refresh:
      payload["scope"] = refreshScope
      if refreshScope == "reviews" {
        addManualReviewPayload(to: &payload)
      }
    }
    if kind == .pullRequestApprove || kind == .pullRequestRerunChecks {
      addManualReviewPayload(to: &payload)
    }
    return payload
  }

  private func addManualReviewPayload(to payload: inout [String: String]) {
    if let repository = repository.trimmedCommandValue {
      payload["repository"] = repository
    }
    if let reviewNumber = reviewNumber.trimmedCommandValue {
      payload["number"] = reviewNumber
    }
  }

  private func submit() async {
    submitting = true
    defer { submitting = false }
    await store.queueCommand(makeDraft())
    dismiss()
  }

  private func seedStationIfNeeded() {
    guard stationID.isEmpty else {
      return
    }
    stationID =
      store.selectedStationID.isEmpty
      ? store.snapshot.stations.first?.id ?? ""
      : store.selectedStationID
  }

  private func seedDefaultsForKind() {
    if kind == .agentStart, agent.trimmedForCommand.isEmpty {
      agent = "codex"
    }
    if kind == .refresh, refreshScope.trimmedForCommand.isEmpty {
      refreshScope = "health"
    }
    if kind == .taskBoardDispatch || kind == .taskBoardPlanApproval, taskID.isEmpty {
      taskID = taskBoardItemsForStation.first(where: \.needsYou)?.id ?? ""
    }
    if isPullRequestCommand(kind), reviewID.isEmpty {
      reviewID = reviewsForStation.first(where: \.needsYou)?.id ?? ""
    }
  }

  private func isPullRequestCommand(_ kind: MobileCommandKind) -> Bool {
    switch kind {
    case .pullRequestApprove, .pullRequestLabel, .pullRequestRerunChecks, .pullRequestMerge:
      true
    default:
      false
    }
  }

  private func clearForeignSelections() {
    if !sessionsForStation.contains(where: { $0.id == sessionID }) {
      sessionID = ""
    }
    if !reviewsForStation.contains(where: { $0.id == reviewID }) {
      reviewID = ""
    }
    if !taskBoardItemsForStation.contains(where: { $0.id == taskID }) {
      taskID = ""
    }
  }
}

extension String {
  fileprivate var trimmedForCommand: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate var trimmedCommandValue: String? {
    let value = trimmedForCommand
    return value.isEmpty ? nil : value
  }

  fileprivate func trimmedForCommandDisplay(ifEmpty fallback: String) -> String {
    let value = trimmedForCommand
    return value.isEmpty ? fallback : value
  }
}

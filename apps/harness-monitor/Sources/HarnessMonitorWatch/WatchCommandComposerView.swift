import HarnessMonitorCore
import SwiftUI

struct WatchCommandComposerView: View {
  @Environment(WatchMonitorStore.self) private var store
  @Environment(\.dismiss) private var dismiss

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
  @State private var agent = "codex"
  @State private var role = "worker"
  @State private var promptPreset = "continue"
  @State private var prompt = ""
  @State private var label = "harness:needs-human"
  @State private var mergeMethod = "squash"
  @State private var refreshScope = "health"
  @State private var auditReason = ""
  @State private var confirmationPresented = false
  @State private var submitting = false

  init(initialStationID: String = "", initialKind: MobileCommandKind = .refresh) {
    _stationID = State(initialValue: initialStationID)
    _kind = State(initialValue: initialKind)
  }

  var body: some View {
    Form {
      Section {
        Picker("Station", selection: $stationID) {
          ForEach(store.snapshot.stations) { station in
            Text(station.displayName).tag(station.id)
          }
        }
        Picker("Command", selection: $kind) {
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
        .disabled(!canSubmit)
      }
    }
    .navigationTitle("New Command")
    .task {
      seedStationIfNeeded()
    }
    .onChange(of: stationID) { _, _ in
      clearForeignSelections()
    }
    .onChange(of: kind) { _, _ in
      seedDefaultsForKind()
    }
    .confirmationDialog(
      confirmationText,
      isPresented: $confirmationPresented,
      titleVisibility: .visible
    ) {
      Button(submitting ? "Queuing..." : "Confirm") {
        Task { await submit() }
      }
      .disabled(submitting)
      Button("Cancel", role: .cancel) {}
    }
  }

  @ViewBuilder
  private var detailsSection: some View {
    Section {
      switch kind {
      case .acpPermissionDecision:
        agentIDField
        TextField("Batch ID", text: $batchID)
        Picker("Decision", selection: $acpDecision) {
          Text("Approve").tag("approve_all")
          Text("Deny").tag("deny_all")
          Text("Some").tag("approve_some")
        }
      case .taskBoardDispatch:
        taskIDField(required: false)
        Picker("Status", selection: $taskStatus) {
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
        TextField("Agent", text: $agent)
        Picker("Role", selection: $role) {
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
        TextField("Label", text: $label)
      case .pullRequestMerge:
        reviewFields
        Picker("Method", selection: $mergeMethod) {
          Text("Squash").tag("squash")
          Text("Merge").tag("merge")
          Text("Rebase").tag("rebase")
        }
        TextField("Audit reason", text: $auditReason)
      case .refresh:
        Picker("Scope", selection: $refreshScope) {
          Text("Mirror").tag("mobileMirror")
          Text("Health").tag("health")
          Text("Reviews").tag("reviews")
          Text("Board").tag("taskBoard")
          Text("Tasks").tag("sessionTasks")
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
    }
  }

  private var agentIDField: some View {
    TextField("Agent ID", text: $agentID)
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
      TextField(required ? "Task ID" : "Task ID optional", text: $taskID)
    }
  }

  private func promptFields(title: String) -> some View {
    Group {
      Picker("Preset", selection: $promptPreset) {
        Text("Continue").tag("continue")
        Text("Summarize").tag("summarize")
        Text("Run tests").tag("tests")
        Text("Handoff").tag("handoff")
        Text("Dictate").tag("custom")
      }
      TextField(title, text: $prompt)
    }
  }

  private var reviewFields: some View {
    Group {
      if !reviewsForStation.isEmpty {
        Picker("PR", selection: $reviewID) {
          Text("Manual").tag("")
          ForEach(reviewsForStation) { review in
            Text(verbatim: "#\(review.number)").tag(review.id)
          }
        }
      }
      TextField("PR ID", text: $reviewID)
      TextField("Repo", text: $repository)
      TextField("Number", text: $reviewNumber)
    }
  }

  private var effectiveStationID: String {
    stationID.isEmpty ? store.snapshot.stations.first?.id ?? "" : stationID
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
        return "Station is not paired."
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
    switch kind {
    case .acpPermissionDecision:
      "\(acpDecision == "deny_all" ? "Deny" : "Approve") permission for \(agentDisplay)."
    case .taskBoardDispatch:
      "Dispatch task board work."
    case .taskBoardPlanApproval:
      "Approve plan \(taskDisplay)."
    case .agentStart:
      "Start \(agent.trimmedDisplay(fallback: "agent")) in \(sessionDisplay)."
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
      "Merge \(reviewDisplay) with \(mergeMethod)."
    case .refresh:
      "Refresh \(refreshScopeDisplay)."
    }
  }

  private var agentDisplay: String {
    agentID.trimmedDisplay(fallback: "agent")
  }

  private var taskDisplay: String {
    taskID.trimmedDisplay(fallback: "task")
  }

  private var sessionDisplay: String {
    sessionID.trimmedDisplay(fallback: "session")
  }

  private var reviewDisplay: String {
    if let review = store.snapshot.reviews.first(where: { $0.id == reviewID }) {
      return "#\(review.number)"
    }
    if !reviewNumber.trimmedForWatchCommand.isEmpty {
      return "#\(reviewNumber.trimmedForWatchCommand)"
    }
    return "PR"
  }

  private var refreshScopeDisplay: String {
    switch refreshScope {
    case "mobileMirror": "mirror"
    case "reviews": "reviews"
    case "taskBoard": "task board"
    case "sessionTasks": "session tasks"
    default: "health"
    }
  }

  private func makeDraft() -> MobileCommandDraft {
    let target = MobileCommandTarget(
      stationID: effectiveStationID,
      sessionID: sessionID.trimmedWatchCommandValue,
      agentID: agentID.trimmedWatchCommandValue,
      reviewID: reviewID.trimmedWatchCommandValue,
      taskID: taskID.trimmedWatchCommandValue,
      targetRevision: store.snapshot.revision
    )
    return MobileCommandDraft(
      kind: kind,
      confirmationText: confirmationText,
      auditReason: auditReason.trimmedWatchCommandValue,
      target: target,
      payload: payload,
      expiresAfter: 10 * 60
    )
  }

  private var payload: [String: String] {
    var payload: [String: String] = [:]
    switch kind {
    case .acpPermissionDecision:
      payload["batchID"] = batchID
      payload["decision"] = acpDecision
    case .taskBoardDispatch:
      payload["status"] = taskStatus
    case .taskBoardPlanApproval, .agentStop, .pullRequestApprove, .pullRequestRerunChecks:
      break
    case .agentStart:
      payload["agent"] = agent
      payload["role"] = role
      payload["prompt"] = promptText
    case .agentPrompt:
      payload["prompt"] = promptText
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

  private var promptText: String {
    if let customPrompt = prompt.trimmedWatchCommandValue {
      return customPrompt
    }
    switch promptPreset {
    case "summarize":
      return "Summarize the current blocker and next action."
    case "tests":
      return "Run the focused validation for your current task and report failures."
    case "handoff":
      return "Prepare a concise handoff with current status, risks, and next steps."
    default:
      return "Continue with the current task and report the next concrete result."
    }
  }

  private func addManualReviewPayload(to payload: inout [String: String]) {
    if let repository = repository.trimmedWatchCommandValue {
      payload["repository"] = repository
    }
    if let reviewNumber = reviewNumber.trimmedWatchCommandValue {
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
    if kind == .agentStart, agent.trimmedForWatchCommand.isEmpty {
      agent = "codex"
    }
    if kind == .pullRequestMerge, auditReason.trimmedForWatchCommand.isEmpty {
      auditReason = "Confirmed from Apple Watch."
    }
    if kind == .taskBoardDispatch || kind == .taskBoardPlanApproval, taskID.isEmpty {
      taskID = taskBoardItemsForStation.first(where: \.needsYou)?.id ?? ""
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
  fileprivate var trimmedForWatchCommand: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate var trimmedWatchCommandValue: String? {
    let value = trimmedForWatchCommand
    return value.isEmpty ? nil : value
  }

  fileprivate func trimmedDisplay(fallback: String) -> String {
    let value = trimmedForWatchCommand
    return value.isEmpty ? fallback : value
  }
}

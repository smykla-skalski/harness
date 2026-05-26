import HarnessMonitorCore
import HarnessMonitorMirrorStore
import SwiftUI

struct MobileCommandComposerView: View {
  @Environment(MirrorStore.self)
  var store
  @Environment(\.dismiss)
  var dismiss

  @State var stationID: String
  @State var kind: MobileCommandKind
  @State var sessionID = ""
  @State var agentID = ""
  @State var taskID = ""
  @State var reviewID = ""
  @State var repository = ""
  @State var reviewNumber = ""
  @State var batchID = ""
  @State var acpDecision = "approve_all"
  @State var taskStatus = ""
  @State var dryRun = false
  @State var agent = "codex"
  @State var role = "worker"
  @State var prompt = ""
  @State var label = ""
  @State var mergeMethod = "squash"
  @State var refreshScope = "health"
  @State var auditReason = ""
  @State var submitting = false

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
}

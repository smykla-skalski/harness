import HarnessMonitorCore
import SwiftUI

struct WatchCommandComposerView: View {
  @Environment(WatchMonitorStore.self)
  var store
  @Environment(\.dismiss)
  var dismiss

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

  @ViewBuilder private var detailsSection: some View {
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
}

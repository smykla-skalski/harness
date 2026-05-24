import HarnessMonitorKit
import SwiftUI

struct TaskActionsReviewWorkflowSection: View {
  let task: WorkItem
  let agents: [AgentRegistration]
  let sessionID: String
  let leaderID: String?
  let store: HarnessMonitorStore
  let areSessionActionsAvailable: Bool
  @Binding var submitForReviewSummary: String
  @Binding var reviewActorID: String
  @Binding var reviewVerdict: ReviewVerdict
  @Binding var reviewSummary: String
  @Binding var reviewPointText: String
  @Binding var reviewResponseNote: String
  @Binding var disputedReviewPointIDs: Set<String>
  @Binding var arbitrationVerdict: ReviewVerdict
  @Binding var arbitrationSummary: String
  let submitForReview: HarnessMonitorActionButton.Action
  let claimReview: HarnessMonitorActionButton.Action
  let submitReview: HarnessMonitorActionButton.Action
  let respondReview: HarnessMonitorActionButton.Action
  let arbitrate: HarnessMonitorActionButton.Action

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text("Review")
        .scaledFont(.headline)
      submitForReviewSection
      claimReviewSection
      submitReviewSection
      respondReviewSection
      arbitrateSection
    }
  }

  @ViewBuilder private var submitForReviewSection: some View {
    if task.status == .inProgress {
      let actorID = TaskActionsSheet.submitForReviewActorID(for: task, agents: agents)
      TextField("Summary", text: $submitForReviewSummary, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(2, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: "Submit for Review",
        actionID: .submitTaskForReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled: !areSessionActionsAvailable || actorID == nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.submitTaskForReviewButton,
        help: actorID == nil ? "Only the assigned worker can submit this task for review" : "",
        action: submitForReview
      )
    }
  }

  @ViewBuilder private var claimReviewSection: some View {
    let candidates = TaskActionsSheet.eligibleReviewClaimAgents(task: task, agents: agents)
    if TaskActionsSheet.matchesReviewQueueStatus(task) {
      if !candidates.isEmpty {
        Picker("Claim As", selection: reviewActorSelection(candidates: candidates)) {
          ForEach(candidates) { agent in
            Text(agent.name).tag(agent.agentId)
          }
        }
        .harnessNativeFormControl()
      } else {
        Text("No eligible reviewer is available for this task")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      HarnessInlineActionButton(
        title: "Claim Review",
        actionID: .claimTaskReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .bordered,
        tint: .secondary,
        isExternallyDisabled: !areSessionActionsAvailable || candidates.isEmpty,
        accessibilityIdentifier: HarnessMonitorAccessibility.claimTaskReviewButton,
        help: candidates.isEmpty ? "No eligible reviewer is available for this task" : "",
        action: claimReview
      )
    }
  }

  @ViewBuilder private var submitReviewSection: some View {
    let candidates = TaskActionsSheet.eligibleReviewSubmitAgents(task: task, agents: agents)
    let summary = reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    if task.status == .inReview {
      if !candidates.isEmpty {
        reviewActorPicker(candidates: candidates)
        reviewVerdictPicker
        TextField("Review summary", text: $reviewSummary, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
        TextField("Review point", text: $reviewPointText, axis: .vertical)
          .harnessNativeFormControl()
          .lineLimit(2, reservesSpace: true)
          .submitLabel(.done)
      } else {
        Text("A claimed reviewer is required before submitting review")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      HarnessInlineActionButton(
        title: "Submit Review",
        actionID: .submitTaskReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: nil,
        isExternallyDisabled:
          !areSessionActionsAvailable
          || candidates.isEmpty
          || summary.isEmpty,
        accessibilityIdentifier: HarnessMonitorAccessibility.submitTaskReviewButton,
        help: submitReviewUnavailableMessage(candidates: candidates, summary: summary),
        action: submitReview
      )
    }
  }

  @ViewBuilder private var respondReviewSection: some View {
    let points = task.consensus?.points ?? []
    let actorID = TaskActionsSheet.respondReviewActorID(for: task, agents: agents)
    if TaskActionsSheet.shouldShowReviewResponse(for: task) {
      if points.isEmpty {
        Text("Consensus has no review points to dispute")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(points) { point in
            Toggle(isOn: disputeBinding(for: point.pointId)) {
              Text(point.text)
                .lineLimit(2)
            }
            .toggleStyle(.checkbox)
          }
        }
      }
      TextField("Response note", text: $reviewResponseNote, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(2, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: "Respond to Review",
        actionID: .respondTaskReview(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .bordered,
        tint: .secondary,
        isExternallyDisabled: !areSessionActionsAvailable || actorID == nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.respondTaskReviewButton,
        help: actorID == nil ? "Only the original worker can respond to consensus" : "",
        action: respondReview
      )
    }
  }

  @ViewBuilder private var arbitrateSection: some View {
    let actorID = TaskActionsSheet.arbitrationActorID(
      for: task,
      leaderID: leaderID,
      agents: agents
    )
    if TaskActionsSheet.isArbitrationBlocked(task) {
      Picker("Arbitration Verdict", selection: $arbitrationVerdict) {
        ForEach(ReviewVerdict.allCases, id: \.self) { verdict in
          Text(verdict.title).tag(verdict)
        }
      }
      .harnessNativeFormControl()
      TextField("Arbitration summary", text: $arbitrationSummary, axis: .vertical)
        .harnessNativeFormControl()
        .lineLimit(2, reservesSpace: true)
        .submitLabel(.done)
      HarnessInlineActionButton(
        title: "Arbitrate",
        actionID: .arbitrateTask(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: HarnessMonitorTheme.caution,
        isExternallyDisabled:
          !areSessionActionsAvailable
          || actorID == nil
          || arbitrationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        accessibilityIdentifier: HarnessMonitorAccessibility.arbitrateTaskButton,
        help: arbitrationUnavailableMessage(actorID: actorID),
        action: arbitrate
      )
    }
  }

  private func reviewActorPicker(candidates: [AgentRegistration]) -> some View {
    Picker("Reviewing As", selection: reviewActorSelection(candidates: candidates)) {
      ForEach(candidates) { agent in
        Text(agent.name).tag(agent.agentId)
      }
    }
    .harnessNativeFormControl()
  }

  private var reviewVerdictPicker: some View {
    Picker("Verdict", selection: $reviewVerdict) {
      ForEach(ReviewVerdict.allCases, id: \.self) { verdict in
        Text(verdict.title).tag(verdict)
      }
    }
    .harnessNativeFormControl()
  }

  private func reviewActorSelection(candidates: [AgentRegistration]) -> Binding<String> {
    Binding(
      get: {
        TaskActionsSheet.normalizedAgentID(
          draftID: reviewActorID,
          availableAgentIDs: candidates.map(\.agentId)
        )
      },
      set: { reviewActorID = $0 }
    )
  }

  private func disputeBinding(for pointID: String) -> Binding<Bool> {
    Binding(
      get: { disputedReviewPointIDs.contains(pointID) },
      set: { isDisputed in
        if isDisputed {
          disputedReviewPointIDs.insert(pointID)
        } else {
          disputedReviewPointIDs.remove(pointID)
        }
      }
    )
  }

  private func submitReviewUnavailableMessage(
    candidates: [AgentRegistration],
    summary: String
  ) -> String {
    if candidates.isEmpty {
      return "A reviewer must claim this task before submitting review"
    }
    if summary.isEmpty {
      return "Review summary is required"
    }
    return ""
  }

  private func arbitrationUnavailableMessage(actorID: String?) -> String {
    if actorID == nil {
      return "Only the current leader can arbitrate this task"
    }
    if arbitrationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Arbitration summary is required"
    }
    return ""
  }
}

struct TaskActionsCheckpointSection: View {
  let task: WorkItem
  let sessionID: String
  let store: HarnessMonitorStore
  let areSessionActionsAvailable: Bool
  let taskMutationUnavailableMessage: String?
  @Binding var checkpointSummary: String
  @Binding var checkpointProgress: Double
  let submitCheckpoint: HarnessMonitorActionButton.Action

  var body: some View {
    let checkpointSummaryValue = checkpointSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    let checkpointUnavailableMessage =
      taskMutationUnavailableMessage
      ?? (checkpointSummaryValue.isEmpty ? "Checkpoint summary is required" : nil)
    Text("Checkpoint")
      .scaledFont(.headline)
    TextField("Summary", text: $checkpointSummary, axis: .vertical)
      .harnessNativeFormControl()
      .lineLimit(3, reservesSpace: true)
      .submitLabel(.done)
    LabeledContent("Progress") {
      Slider(value: $checkpointProgress, in: 0...100, step: 5)
        .harnessNativeFormControl()
        .accessibilityValue("\(Int(checkpointProgress)) percent complete")
        .accessibilityHint("Sets the completion percentage for this checkpoint")
    }
    HStack {
      Text("\(Int(checkpointProgress))%")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer()
      HarnessInlineActionButton(
        title: "Save Checkpoint",
        actionID: .checkpointTask(sessionID: sessionID, taskID: task.taskId),
        store: store,
        variant: .prominent,
        tint: HarnessMonitorTheme.caution,
        isExternallyDisabled:
          !areSessionActionsAvailable || checkpointUnavailableMessage != nil,
        accessibilityIdentifier: HarnessMonitorAccessibility.checkpointTaskButton,
        help: checkpointUnavailableMessage ?? "",
        action: submitCheckpoint
      )
    }
    if let checkpointUnavailableMessage {
      Text(checkpointUnavailableMessage)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    if let checkpoint = task.checkpointSummary {
      Text("Latest: \(checkpoint.progress)% · \(checkpoint.summary)")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }
}

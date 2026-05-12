import HarnessMonitorKit
import SwiftUI

struct SessionTaskDetailPane: View {
  let task: WorkItem
  let openActions: () -> Void
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionTaskDetailPaneMetrics {
    SessionTaskDetailPaneMetrics(fontScale: fontScale)
  }

  var body: some View {
    SessionDetailScrollSurface(contentPadding: metrics.contentPadding) {
      VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
        SessionDetailPanel(title: "Task") {
          SessionDetailFactsGrid(
            facts: [
              SessionDetailFact("Title", value: task.title),
              SessionDetailFact("Status", value: task.status.title),
              SessionDetailFact("Severity", value: task.severity.title),
              SessionDetailFact("Source", value: task.source.title),
              SessionDetailFact("Assignment", value: task.assignmentSummary),
              SessionDetailFact("Queue Policy", value: task.queuePolicy.title),
            ]
          )
          Button("Task Actions", action: openActions)
            .harnessNativeFormControl()
            .accessibilityHint("Opens assignment, status, and checkpoint actions for this task")
        }
        if let context = task.context, !context.isEmpty {
          SessionDetailPanel(title: "Context") {
            detailText(context)
          }
        }
        if let suggestedFix = task.suggestedFix, !suggestedFix.isEmpty {
          SessionDetailPanel(title: "Suggested Fix") {
            detailText(suggestedFix)
          }
        }
        SessionDetailPanel(title: "Timing") {
          SessionDetailFactsGrid(facts: timingFacts)
        }
        if let checkpoint = task.checkpointSummary {
          SessionDetailPanel(title: "Latest Checkpoint") {
            SessionDetailFactsGrid(facts: checkpointFacts(checkpoint))
            detailText(checkpoint.summary)
          }
        }
        if !task.notes.isEmpty {
          SessionDetailPanel(title: "Notes") {
            ForEach(task.notes) { note in
              VStack(alignment: .leading, spacing: metrics.noteSpacing) {
                detailText(note.text)
                HStack(spacing: metrics.metaSpacing) {
                  Text(verbatim: note.timestamp)
                  if let agentID = note.agentId {
                    Text(verbatim: agentID)
                  }
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
        }
        if task.reviewRound > 0 || task.awaitingReview != nil || task.reviewClaim != nil {
          SessionDetailPanel(title: "Review") {
            SessionDetailFactsGrid(facts: reviewFacts)
            if let awaitingReview = task.awaitingReview {
              if let summary = awaitingReview.summary {
                detailText(summary)
              }
            }
          }
        }
        if let arbitration = task.arbitration {
          SessionDetailPanel(title: "Arbitration") {
            SessionDetailFactsGrid(facts: arbitrationFacts(arbitration))
            detailText(arbitration.summary)
          }
        }
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTaskDetailScrollView)
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }

  private var timingFacts: [SessionDetailFact] {
    var facts = [
      SessionDetailFact("Created", value: task.createdAt),
      SessionDetailFact("Updated", value: task.updatedAt),
    ]
    if let completedAt = task.completedAt {
      facts.append(SessionDetailFact("Completed", value: completedAt))
    }
    return facts
  }

  private func checkpointFacts(_ checkpoint: TaskCheckpointSummary) -> [SessionDetailFact] {
    var facts = [
      SessionDetailFact("Progress", value: "\(checkpoint.progress)%"),
      SessionDetailFact("Recorded", value: checkpoint.recordedAt),
    ]
    if let actorID = checkpoint.actorId {
      facts.append(SessionDetailFact("Actor", value: actorID))
    }
    return facts
  }

  private var reviewFacts: [SessionDetailFact] {
    var facts = [SessionDetailFact("Round", value: "\(task.reviewRound)")]
    if let awaitingReview = task.awaitingReview {
      facts.append(SessionDetailFact("Submitter", value: awaitingReview.submitterAgentId))
      facts.append(
        SessionDetailFact(
          "Required Consensus",
          value: "\(awaitingReview.requiredConsensus)"
        )
      )
    }
    if let reviewClaim = task.reviewClaim {
      facts.append(SessionDetailFact("Reviewers", value: "\(reviewClaim.reviewers.count)"))
    }
    return facts
  }

  private func arbitrationFacts(_ arbitration: ArbitrationOutcome) -> [SessionDetailFact] {
    [
      SessionDetailFact("Arbiter", value: arbitration.arbiterAgentId),
      SessionDetailFact("Verdict", value: arbitration.verdict.title),
      SessionDetailFact("Recorded", value: arbitration.recordedAt),
    ]
  }

  private func detailText(_ value: String) -> some View {
    Text(verbatim: value)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionTaskDetailPaneMetrics: Equatable {
  let contentPadding: CGFloat
  let sectionSpacing: CGFloat
  let noteSpacing: CGFloat
  let metaSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    contentPadding = max(24, 24 * min(scale, 1.35))
    sectionSpacing = max(16, 16 * min(scale, 1.35))
    noteSpacing = max(4, 4 * min(scale, 1.45))
    metaSpacing = max(6, 6 * min(scale, 1.35))
  }
}

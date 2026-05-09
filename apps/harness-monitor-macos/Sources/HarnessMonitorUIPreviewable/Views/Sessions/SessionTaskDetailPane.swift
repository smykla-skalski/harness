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
          VStack(alignment: .leading, spacing: metrics.panelContentSpacing) {
            SessionDetailFactsGrid(facts: taskFacts)
            Button("Task Actions", action: openActions)
              .harnessNativeFormControl()
              .accessibilityHint("Opens assignment, status, and checkpoint actions for this task")
          }
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
            VStack(alignment: .leading, spacing: metrics.panelContentSpacing) {
              SessionDetailFactsGrid(facts: checkpointFacts(checkpoint))
              detailText(checkpoint.summary)
            }
          }
        }

        if !task.notes.isEmpty {
          SessionDetailPanel(title: "Notes") {
            VStack(alignment: .leading, spacing: metrics.noteSpacing) {
              ForEach(Array(task.notes.enumerated()), id: \.element.id) { index, note in
                VStack(alignment: .leading, spacing: metrics.noteSpacing) {
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
                  Divider()
                    .opacity(index < task.notes.count - 1 ? 1 : 0)
                }
              }
            }
          }
        }

        if task.reviewRound > 0 || task.awaitingReview != nil || task.reviewClaim != nil {
          SessionDetailPanel(title: "Review") {
            VStack(alignment: .leading, spacing: metrics.panelContentSpacing) {
              SessionDetailFactsGrid(facts: reviewFacts)
              if let summary = task.awaitingReview?.summary {
                detailText(summary)
              }
            }
          }
        }

        if let arbitration = task.arbitration {
          SessionDetailPanel(title: "Arbitration") {
            VStack(alignment: .leading, spacing: metrics.panelContentSpacing) {
              SessionDetailFactsGrid(facts: arbitrationFacts(arbitration))
              detailText(arbitration.summary)
            }
          }
        }
      }
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }

  private var taskFacts: [SessionDetailFact] {
    [
      .init("Title", value: task.title),
      .init("Status", value: task.status.title),
      .init("Severity", value: task.severity.title),
      .init("Source", value: task.source.title),
      .init("Assignment", value: task.assignmentSummary),
      .init("Queue Policy", value: task.queuePolicy.title),
    ]
  }

  private var timingFacts: [SessionDetailFact] {
    var facts: [SessionDetailFact] = [
      .init("Created", value: task.createdAt),
      .init("Updated", value: task.updatedAt),
    ]
    if let completedAt = task.completedAt {
      facts.append(.init("Completed", value: completedAt))
    }
    return facts
  }

  private var reviewFacts: [SessionDetailFact] {
    var facts: [SessionDetailFact] = [
      .init("Round", value: "\(task.reviewRound)")
    ]
    if let awaitingReview = task.awaitingReview {
      facts.append(.init("Submitter", value: awaitingReview.submitterAgentId))
      facts.append(.init("Required Consensus", value: "\(awaitingReview.requiredConsensus)"))
    }
    if let reviewClaim = task.reviewClaim {
      facts.append(.init("Reviewers", value: "\(reviewClaim.reviewers.count)"))
    }
    return facts
  }

  private func checkpointFacts(_ checkpoint: TaskCheckpointSummary) -> [SessionDetailFact] {
    var facts: [SessionDetailFact] = [
      .init("Progress", value: "\(checkpoint.progress)%"),
      .init("Recorded", value: checkpoint.recordedAt),
    ]
    if let actorID = checkpoint.actorId {
      facts.append(.init("Actor", value: actorID))
    }
    return facts
  }

  private func arbitrationFacts(_ arbitration: ArbitrationOutcome) -> [SessionDetailFact] {
    [
      .init("Arbiter", value: arbitration.arbiterAgentId),
      .init("Verdict", value: arbitration.verdict.title),
      .init("Recorded", value: arbitration.recordedAt),
    ]
  }

  private func detailText(_ value: String) -> some View {
    Text(verbatim: value)
      .scaledFont(.body)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionTaskDetailPaneMetrics: Equatable {
  let contentPadding: CGFloat
  let sectionSpacing: CGFloat
  let panelContentSpacing: CGFloat
  let noteSpacing: CGFloat
  let metaSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    contentPadding = max(24, 24 * min(scale, 1.35))
    sectionSpacing = max(16, 16 * min(scale, 1.35))
    panelContentSpacing = max(10, 10 * min(scale, 1.45))
    noteSpacing = max(4, 4 * min(scale, 1.45))
    metaSpacing = max(6, 6 * min(scale, 1.35))
  }
}

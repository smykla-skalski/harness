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
    Form {
      Section("Task") {
        LabeledContent("Title", value: task.title)
        LabeledContent("Status", value: task.status.title)
        LabeledContent("Severity", value: task.severity.title)
        LabeledContent("Source", value: task.source.title)
        LabeledContent("Assignment", value: task.assignmentSummary)
        LabeledContent("Queue Policy", value: task.queuePolicy.title)
        Button("Task Actions", action: openActions)
          .accessibilityHint("Opens assignment, status, and checkpoint actions for this task")
      }

      if let context = task.context, !context.isEmpty {
        Section("Context") {
          Text(context)
            .textSelection(.enabled)
        }
      }

      if let suggestedFix = task.suggestedFix, !suggestedFix.isEmpty {
        Section("Suggested Fix") {
          Text(suggestedFix)
            .textSelection(.enabled)
        }
      }

      Section("Timing") {
        LabeledContent("Created", value: task.createdAt)
        LabeledContent("Updated", value: task.updatedAt)
        if let completedAt = task.completedAt {
          LabeledContent("Completed", value: completedAt)
        }
      }

      if let checkpoint = task.checkpointSummary {
        Section("Latest Checkpoint") {
          LabeledContent("Progress", value: "\(checkpoint.progress)%")
          LabeledContent("Recorded", value: checkpoint.recordedAt)
          if let actorID = checkpoint.actorId {
            LabeledContent("Actor", value: actorID)
          }
          Text(checkpoint.summary)
            .textSelection(.enabled)
        }
      }

      if !task.notes.isEmpty {
        Section("Notes") {
          ForEach(task.notes) { note in
            VStack(alignment: .leading, spacing: metrics.noteSpacing) {
              Text(note.text)
              HStack(spacing: metrics.metaSpacing) {
                Text(note.timestamp)
                if let agentID = note.agentId {
                  Text(agentID)
                }
              }
              .scaledFont(.caption)
              .foregroundStyle(.secondary)
            }
          }
        }
      }

      if task.reviewRound > 0 || task.awaitingReview != nil || task.reviewClaim != nil {
        Section("Review") {
          LabeledContent("Round", value: "\(task.reviewRound)")
          if let awaitingReview = task.awaitingReview {
            LabeledContent("Submitter", value: awaitingReview.submitterAgentId)
            LabeledContent("Required Consensus", value: "\(awaitingReview.requiredConsensus)")
            if let summary = awaitingReview.summary {
              Text(summary)
                .textSelection(.enabled)
            }
          }
          if let reviewClaim = task.reviewClaim {
            LabeledContent("Reviewers", value: "\(reviewClaim.reviewers.count)")
          }
        }
      }

      if let arbitration = task.arbitration {
        Section("Arbitration") {
          LabeledContent("Arbiter", value: arbitration.arbiterAgentId)
          LabeledContent("Verdict", value: arbitration.verdict.title)
          LabeledContent("Recorded", value: arbitration.recordedAt)
          Text(arbitration.summary)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .padding(metrics.contentPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }
}

struct SessionTaskDetailPaneMetrics: Equatable {
  let contentPadding: CGFloat
  let noteSpacing: CGFloat
  let metaSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    contentPadding = max(24, 24 * min(scale, 1.35))
    noteSpacing = max(4, 4 * min(scale, 1.45))
    metaSpacing = max(6, 6 * min(scale, 1.35))
  }
}

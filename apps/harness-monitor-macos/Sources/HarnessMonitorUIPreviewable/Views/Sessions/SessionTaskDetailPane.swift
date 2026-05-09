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
    SessionDetailScrollSurface(contentPadding: 0) {
      Form {
        Section {
          LabeledContent("Title", value: task.title)
          LabeledContent("Status", value: task.status.title)
          LabeledContent("Severity", value: task.severity.title)
          LabeledContent("Source", value: task.source.title)
          LabeledContent("Assignment", value: task.assignmentSummary)
          LabeledContent("Queue Policy", value: task.queuePolicy.title)
          Button("Task Actions", action: openActions)
            .harnessNativeFormControl()
            .accessibilityHint("Opens assignment, status, and checkpoint actions for this task")
        } header: {
          Text("Task")
            .harnessNativeFormSectionHeader()
        }

        if let context = task.context, !context.isEmpty {
          Section {
            detailText(context)
          } header: {
            Text("Context")
              .harnessNativeFormSectionHeader()
          }
        }

        if let suggestedFix = task.suggestedFix, !suggestedFix.isEmpty {
          Section {
            detailText(suggestedFix)
          } header: {
            Text("Suggested Fix")
              .harnessNativeFormSectionHeader()
          }
        }

        Section {
          LabeledContent("Created", value: task.createdAt)
          LabeledContent("Updated", value: task.updatedAt)
          if let completedAt = task.completedAt {
            LabeledContent("Completed", value: completedAt)
          }
        } header: {
          Text("Timing")
            .harnessNativeFormSectionHeader()
        }

        if let checkpoint = task.checkpointSummary {
          Section {
            LabeledContent("Progress", value: "\(checkpoint.progress)%")
            LabeledContent("Recorded", value: checkpoint.recordedAt)
            if let actorID = checkpoint.actorId {
              LabeledContent("Actor", value: actorID)
            }
            detailText(checkpoint.summary)
          } header: {
            Text("Latest Checkpoint")
              .harnessNativeFormSectionHeader()
          }
        }

        if !task.notes.isEmpty {
          Section {
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
          } header: {
            Text("Notes")
              .harnessNativeFormSectionHeader()
          }
        }

        if task.reviewRound > 0 || task.awaitingReview != nil || task.reviewClaim != nil {
          Section {
            LabeledContent("Round", value: "\(task.reviewRound)")
            if let awaitingReview = task.awaitingReview {
              LabeledContent("Submitter", value: awaitingReview.submitterAgentId)
              LabeledContent("Required Consensus", value: "\(awaitingReview.requiredConsensus)")
              if let summary = awaitingReview.summary {
                detailText(summary)
              }
            }
            if let reviewClaim = task.reviewClaim {
              LabeledContent("Reviewers", value: "\(reviewClaim.reviewers.count)")
            }
          } header: {
            Text("Review")
              .harnessNativeFormSectionHeader()
          }
        }

        if let arbitration = task.arbitration {
          Section {
            LabeledContent("Arbiter", value: arbitration.arbiterAgentId)
            LabeledContent("Verdict", value: arbitration.verdict.title)
            LabeledContent("Recorded", value: arbitration.recordedAt)
            detailText(arbitration.summary)
          } header: {
            Text("Arbitration")
              .harnessNativeFormSectionHeader()
          }
        }
      }
      .harnessNativeFormContainer()
      .contentMargins(.horizontal, metrics.contentPadding, for: .scrollContent)
      .contentMargins(.vertical, metrics.contentPadding, for: .scrollContent)
      .scrollDisabled(true)
      .scrollContentBackground(.hidden)
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }

  private func detailText(_ value: String) -> some View {
    Text(verbatim: value)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
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

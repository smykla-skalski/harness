import HarnessMonitorKit
import SwiftUI

struct TaskInspectorCard: View {
  let store: HarnessMonitorStore
  let task: WorkItem
  let notesSessionID: String?
  let isPersistenceAvailable: Bool

  private var facts: [InspectorFact] {
    [
      .init(title: "Severity", value: task.severity.title),
      .init(title: "Status", value: task.status.title),
      .init(title: "Assignee", value: task.assignmentSummary),
      .init(title: "Queue Policy", value: task.queuePolicy.title),
      .init(title: "Source", value: task.source.title),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text(task.title)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text(task.context ?? "No task context provided.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if task.source == .improver {
        ImproverTaskCardView(task: task)
      }
      InspectorFactGrid(facts: facts)
      InspectorReviewStateSection(task: task)
      if let checkpoint = task.checkpointSummary {
        InspectorSection(title: "Checkpoint") {
          InspectorFactGrid(
            facts: [
              .init(title: "Progress", value: "\(checkpoint.progress)%"),
              .init(title: "Recorded", value: formatTimestamp(checkpoint.recordedAt)),
            ]
          )
          Text(checkpoint.summary)
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if let suggestion = task.suggestedFix {
        InspectorSection(title: "Suggested Fix") {
          Text(suggestion)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if !task.notes.isEmpty {
        InspectorSection(title: "Notes") {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(task.notes) { note in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(note.agentId ?? "system")
                    .scaledFont(.caption.bold())
                  Spacer()
                  Text(formatTimestamp(note.timestamp))
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                }
                Text(note.text)
                  .scaledFont(.subheadline)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
              .harnessCellPadding()
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if let blockedReason = task.blockedReason, !blockedReason.isEmpty {
        InspectorSection(title: "Blocked Reason") {
          Text(blockedReason)
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.danger)
        }
      }
      if let completedAt = task.completedAt {
        InspectorSection(title: "Completed") {
          Text(formatTimestamp(completedAt))
            .scaledFont(.subheadline.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      InspectorSection(title: "Your Notes") {
        if let notesSessionID, isPersistenceAvailable {
          TaskUserNotesSection(
            store: store,
            taskID: task.taskId,
            sessionID: notesSessionID
          )
        } else {
          PersistenceUnavailableNotesState()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.taskInspectorCard,
      label: task.title,
      value: task.taskId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.taskInspectorCard).frame")
  }
}

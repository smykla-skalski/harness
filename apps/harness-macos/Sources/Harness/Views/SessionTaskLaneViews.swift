import HarnessKit
import SwiftUI

struct SessionTaskListSection: View {
  let tasks: [WorkItem]
  let inspectTask: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Tasks")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if tasks.isEmpty {
        ContentUnavailableView {
          Label("No tasks yet", systemImage: "checklist")
        } description: {
          Text("Create a task from the Action Console in the inspector.")
        }
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
          ForEach(tasks) { task in
            SessionTaskSummaryCard(task: task, inspectTask: inspectTask)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionTaskSummaryCard: View {
  let task: WorkItem
  let inspectTask: (String) -> Void

  var body: some View {
    Button { inspectTask(task.taskId) } label: {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        HStack(alignment: .top) {
          Text(task.title)
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(2)
          Spacer()
          Text(task.severity.title)
            .scaledFont(.caption.bold())
            .harnessPillPadding()
            .background(severityColor(for: task.severity), in: Capsule())
            .foregroundStyle(HarnessTheme.onContrast)
        }
        Text(task.context ?? "No extra context")
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessTheme.secondaryInk)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
        Spacer(minLength: 0)
        HStack(alignment: .firstTextBaseline) {
          Text(task.status.title)
            .scaledFont(.caption.weight(.bold))
            .foregroundStyle(taskStatusColor(for: task.status))
          Spacer()
          Text(task.assignedTo ?? "unassigned")
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(
        maxWidth: .infinity,
        minHeight: SessionCockpitLayout.laneCardHeight,
        alignment: .topLeading
      )
      .padding(HarnessTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
    .contextMenu {
      Button { inspectTask(task.taskId) } label: {
        Label("Inspect", systemImage: "info.circle")
      }
      Divider()
      Button {
        HarnessClipboard.copy(task.taskId)
      } label: {
        Label("Copy Task ID", systemImage: "doc.on.doc")
      }
    }
    .accessibilityIdentifier(HarnessAccessibility.sessionTaskCard(task.taskId))
    .accessibilityFrameMarker("\(HarnessAccessibility.sessionTaskCard(task.taskId)).frame")
    .transition(
      .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity),
        removal: .opacity
      ))
  }
}

#Preview("Task summary") {
  SessionTaskSummaryCard(task: PreviewFixtures.tasks[0], inspectTask: { _ in })
    .padding()
    .frame(width: 320)
}

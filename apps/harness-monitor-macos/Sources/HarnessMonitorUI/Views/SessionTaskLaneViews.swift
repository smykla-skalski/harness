import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskDragPayload: Codable, Transferable {
  let sessionID: String
  let taskID: String

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorTask)
  }
}

extension UTType {
  static let harnessMonitorTask = UTType(exportedAs: "io.harnessmonitor.task")
}

struct SessionTaskListSection: View {
  let sessionID: String
  let tasks: [WorkItem]
  let isSessionReadOnly: Bool
  let companionAgentCount: Int
  let inspectTask: (String) -> Void

  private var emptyStateMinHeight: CGFloat {
    let visibleAgentCards = max(companionAgentCount, 1)
    let cardHeights = CGFloat(visibleAgentCards) * SessionCockpitLayout.laneCardFootprint
    let interCardSpacing =
      CGFloat(max(visibleAgentCards - 1, 0)) * HarnessMonitorTheme.sectionSpacing
    return cardHeights + interCardSpacing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Tasks")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if tasks.isEmpty {
        ContentUnavailableView {
          Label("No tasks yet", systemImage: "checklist")
        } description: {
          Text("Create a task from the Action Console in the inspector.")
        }
        .foregroundStyle(.tertiary)
        .frame(
          maxWidth: .infinity,
          minHeight: emptyStateMinHeight,
          alignment: .center
        )
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          ForEach(tasks) { task in
            SessionTaskSummaryCard(
              sessionID: sessionID,
              task: task,
              isDragEnabled: !isSessionReadOnly && task.isDraggableForWorkerDrop,
              inspectTask: inspectTask
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct SessionTaskSummaryCard: View {
  let sessionID: String
  let task: WorkItem
  let isDragEnabled: Bool
  let inspectTask: (String) -> Void

  private var dragPayload: TaskDragPayload {
    TaskDragPayload(sessionID: sessionID, taskID: task.taskId)
  }

  var body: some View {
    cardButton
      .taskCardDrag(payload: dragPayload, isEnabled: isDragEnabled)
      .contextMenu {
        Button {
          inspectTask(task.taskId)
        } label: {
          Label("Inspect", systemImage: "info.circle")
        }
        Divider()
        Button {
          HarnessMonitorClipboard.copy(task.taskId)
        } label: {
          Label("Copy Task ID", systemImage: "doc.on.doc")
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTaskCard(task.taskId))
      .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sessionTaskCard(task.taskId)).frame")
  }

  private var cardButton: some View {
    Button {
      inspectTask(task.taskId)
    } label: {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        HStack(alignment: .top) {
          Text(task.title)
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            .lineLimit(2)
          Spacer()
          Text(task.severity.title)
            .scaledFont(.caption.bold())
            .harnessPillPadding()
            .background(severityColor(for: task.severity), in: Capsule())
            .foregroundStyle(HarnessMonitorTheme.onContrast)
        }
        Text(task.context ?? "No extra context")
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .multilineTextAlignment(.leading)
          .lineLimit(2)
        Spacer(minLength: 0)
        HStack(alignment: .firstTextBaseline) {
          Text(task.assignmentStateTitle)
            .scaledFont(.caption.weight(.bold))
            .foregroundStyle(task.assignmentStateColor)
          Spacer()
          Text(task.assignmentSummary)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(
        maxWidth: .infinity,
        minHeight: SessionCockpitLayout.laneCardHeight,
        alignment: .topLeading
      )
      .padding(HarnessMonitorTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
  }
}

#Preview("Task summary") {
  SessionTaskSummaryCard(
    sessionID: PreviewFixtures.summary.sessionId,
    task: PreviewFixtures.tasks[0],
    isDragEnabled: true,
    inspectTask: { _ in }
  )
    .padding()
    .frame(width: 320)
}

private extension View {
  @ViewBuilder
  func taskCardDrag(payload: TaskDragPayload, isEnabled: Bool) -> some View {
    if isEnabled {
      draggable(payload) {
        Text(payload.taskID)
          .scaledFont(.caption.bold())
          .harnessPillPadding()
          .harnessContentPill()
      }
    } else {
      self
    }
  }
}

private extension WorkItem {
  var isDraggableForWorkerDrop: Bool {
    isLeaderAssignable || isReassignableQueuedTask
  }

  var assignmentStateTitle: String {
    if isQueuedForWorker {
      return queuePolicy == .reassignWhenFree ? "Queued · reassignable" : "Queued"
    }
    return status.title
  }

  var assignmentStateColor: Color {
    isQueuedForWorker ? HarnessMonitorTheme.caution : taskStatusColor(for: status)
  }
}

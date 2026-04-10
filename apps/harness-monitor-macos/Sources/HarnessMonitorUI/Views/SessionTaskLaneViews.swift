import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskDragPayload: Codable, Transferable {
  let sessionID: String
  let taskID: String
  let queuePolicy: TaskQueuePolicy

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorTask)
  }
}

extension UTType {
  static let harnessMonitorTask = UTType(exportedAs: "io.harnessmonitor.task", conformingTo: .json)
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
  @State private var isHovered = false
  @State private var isDragPreviewPresented = false

  private var dragPayload: TaskDragPayload {
    TaskDragPayload(
      sessionID: sessionID,
      taskID: task.taskId,
      queuePolicy: task.queuePolicy
    )
  }

  private var isDragging: Bool {
    isDragEnabled && isDragPreviewPresented
  }

  var body: some View {
    ZStack {
      cardSurface
    }
      .background {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .fill(Color.primary.opacity(isDragging || isHovered ? 0.08 : 0.04))
      }
      .overlay {
        if isDragging {
          TaskDraggingOverlay()
            .transition(.opacity)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .strokeBorder(
            isDragging ? HarnessMonitorTheme.accent : Color.clear,
            lineWidth: isDragging ? 2 : 0
          )
      }
      .opacity(isDragging ? 0.82 : 1)
      .scaleEffect(isDragging ? 0.985 : 1)
      .contentShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD))
      .taskCardDrag(
        payload: dragPayload,
        isEnabled: isDragEnabled,
        previewDidChangePresentation: setDragPreviewPresented
      )
      .onContinuousHover { phase in
        withAnimation(.easeOut(duration: 0.15)) {
          switch phase {
          case .active:
            isHovered = true
          case .ended:
            isHovered = false
          }
        }
      }
      .onTapGesture {
        inspectTask(task.taskId)
      }
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
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        inspectTask(task.taskId)
      }
      .accessibilityValue(isDragging ? "Dragging" : "")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTaskCard(task.taskId))
      .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sessionTaskCard(task.taskId)).frame")
      .animation(isDragging ? .easeOut(duration: 0.10) : nil, value: isDragging)
  }

  private func setDragPreviewPresented(_ isPresented: Bool) {
    guard isDragPreviewPresented != isPresented else {
      return
    }
    isDragPreviewPresented = isPresented
    if !isPresented {
      isHovered = false
    }
  }

  private var cardSurface: some View {
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
  func taskCardDrag(
    payload: TaskDragPayload,
    isEnabled: Bool,
    previewDidChangePresentation: @escaping (Bool) -> Void
  ) -> some View {
    if isEnabled {
      draggable(payload) {
        TaskDragPreview(
          taskID: payload.taskID,
          didChangePresentation: previewDidChangePresentation
        )
      }
    } else {
      self
    }
  }
}

private struct TaskDraggingOverlay: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(.regularMaterial)
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.accent.opacity(0.18))
      Circle()
        .fill(HarnessMonitorTheme.accent.opacity(0.32))
        .frame(width: 112, height: 112)
        .blur(radius: 24)
      TaskDragGestureIcon(size: 44)
        .foregroundStyle(HarnessMonitorTheme.accent)
    }
    .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct TaskDragPreview: View {
  let taskID: String
  let didChangePresentation: (Bool) -> Void

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      TaskDragGestureIcon(size: 14)
        .foregroundStyle(HarnessMonitorTheme.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("Assign task")
          .scaledFont(.caption.weight(.bold))
        Text(taskID)
          .scaledFont(.caption2.monospaced())
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(HarnessMonitorTheme.accent.opacity(0.5), lineWidth: 1)
    }
    .onAppear {
      didChangePresentation(true)
    }
    .onDisappear {
      didChangePresentation(false)
    }
  }
}

private struct TaskDragGestureIcon: View {
  let size: CGFloat

  var body: some View {
    HarnessMonitorUIAssets.image(named: "TaskDragHandGesture")
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
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

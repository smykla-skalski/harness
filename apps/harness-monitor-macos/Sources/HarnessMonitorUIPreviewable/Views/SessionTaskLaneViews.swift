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
  let store: HarnessMonitorStore
  let sessionID: String
  let tasks: [WorkItem]
  let inspectTask: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Tasks")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if tasks.isEmpty {
        SessionCockpitEmptyStateRow(section: .tasks)
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          ForEach(tasks) { task in
            SessionTaskSummaryCard(
              store: store,
              sessionID: sessionID,
              task: task,
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
  let store: HarnessMonitorStore
  let sessionID: String
  let task: WorkItem
  let inspectTask: (String) -> Void
  @State private var dragPhase: DragSession.Phase?

  private var dragPayload: TaskDragPayload {
    TaskDragPayload(
      sessionID: sessionID,
      taskID: task.taskId,
      queuePolicy: task.queuePolicy
    )
  }

  private var isDragging: Bool {
    switch dragPhase {
    case .initial, .active:
      true
    default:
      false
    }
  }

  var body: some View {
    Button {
      inspectTask(task.taskId)
    } label: {
      cardSurface
    }
    .harnessInteractiveCardButtonStyle()
    .overlay {
      if isDragging {
        TaskDraggingOverlay()
          .transition(.opacity)
      }
    }
    .clipShape(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(
          isDragging ? HarnessMonitorTheme.accent : Color.clear,
          lineWidth: isDragging ? 2 : 0
        )
    }
    .opacity(isDragging ? 0.82 : 1)
    .scaleEffect(isDragging ? 0.985 : 1)
    .draggable(dragPayload) {
      TaskDragPreviewCard(task: task)
    }
    .onDragSessionUpdated { session in
      updateDragSession(session)
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
    .accessibilityValue(isDragging ? "Dragging" : "")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTaskCard(task.taskId))
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sessionTaskCard(task.taskId)).frame")
    .animation(.easeOut(duration: 0.10), value: isDragging)
    .onDisappear {
      if isDragging {
        store.contentUI.session.isTaskDragActive = false
      }
    }
  }

  private func updateDragSession(_ session: DragSession) {
    switch session.phase {
    case .initial, .active:
      dragPhase = session.phase
      store.contentUI.session.isTaskDragActive = true
    case .ended, .dataTransferCompleted:
      dragPhase = nil
      store.contentUI.session.isTaskDragActive = false
    @unknown default:
      dragPhase = nil
      store.contentUI.session.isTaskDragActive = false
    }
  }

  private var cardSurface: some View {
    SessionTaskCompactSummaryContent(task: task)
      .frame(
        maxWidth: .infinity,
        alignment: .leading
      )
      .padding(HarnessMonitorTheme.cardPadding)
  }
}

#Preview("Task summary") {
  SessionTaskSummaryCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    task: PreviewFixtures.tasks[0],
    inspectTask: { _ in }
  )
  .padding()
  .frame(width: 320)
}

private struct TaskDraggingOverlay: View {
  var body: some View {
    GeometryReader { proxy in
      let metrics = TaskDragFeedbackMetrics(cardSize: proxy.size)
      ZStack {
        Color.clear
          .harnessDragFeedbackSurface(
            cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
            tint: HarnessMonitorTheme.accent
          )
        Circle()
          .fill(HarnessMonitorTheme.accent.opacity(0.32))
          .frame(width: metrics.haloDiameter, height: metrics.haloDiameter)
          .blur(radius: metrics.blurRadius)
        TaskDragGestureIcon(size: metrics.iconSize)
          .foregroundStyle(HarnessMonitorTheme.accent)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .clipShape(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct SessionTaskCompactSummaryContent: View {
  let task: WorkItem

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
        Text(task.title)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
        Spacer(minLength: HarnessMonitorTheme.spacingXS)
        Text(task.severity.title)
          .scaledFont(.caption.bold())
          .harnessPillPadding()
          .background(severityColor(for: task.severity), in: Capsule())
          .foregroundStyle(HarnessMonitorTheme.onContrast)
      }
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
        Text(task.assignmentStateTitle)
          .scaledFont(.caption.weight(.bold))
          .foregroundStyle(task.assignmentStateColor)
          .lineLimit(1)
        Spacer(minLength: HarnessMonitorTheme.spacingXS)
        Text(task.assignmentSummary)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }
}

struct TaskDragPreviewCard: View {
  let task: WorkItem

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "list.bullet.clipboard")
        .imageScale(.small)
        .foregroundStyle(HarnessMonitorTheme.accent)
      Text(task.title)
        .scaledFont(.caption.weight(.bold))
        .lineLimit(1)
        .truncationMode(.tail)
        .layoutPriority(1)
      Text(task.severity.title)
        .scaledFont(.caption2.bold())
        .harnessPillPadding()
        .background(severityColor(for: task.severity), in: Capsule())
        .foregroundStyle(HarnessMonitorTheme.onContrast)
        .fixedSize()
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .harnessDragFeedbackSurface(
      cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
      tint: HarnessMonitorTheme.accent
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .stroke(HarnessMonitorTheme.accent.opacity(0.5), lineWidth: 1)
    }
    .frame(maxWidth: 320, alignment: .leading)
  }
}

struct TaskDragFeedbackMetrics {
  let haloDiameter: CGFloat
  let blurRadius: CGFloat
  let iconSize: CGFloat

  var totalFootprint: CGFloat {
    haloDiameter + (blurRadius * 2)
  }

  init(cardSize: CGSize) {
    let minimumDimension = max(1, min(cardSize.width, cardSize.height))
    // Let the glow bleed beyond the compact card's inner footprint; the overlay is clipped
    // to the card chrome, so the larger blur reads stronger without overflowing the row.
    let glowBleedAllowance = minimumDimension * 0.28
    let maximumFootprint = max(
      24,
      minimumDimension - (HarnessMonitorTheme.spacingSM * 2) + glowBleedAllowance
    )
    let blurScale: CGFloat = 0.32
    let maximumHalo = maximumFootprint / (1 + (blurScale * 2))

    haloDiameter = max(24, min(maximumHalo, minimumDimension * 0.76))
    blurRadius = max(8, haloDiameter * blurScale)
    iconSize = min(max(16, haloDiameter * 0.52), minimumDimension * 0.42)
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

extension WorkItem {
  fileprivate var assignmentStateTitle: String {
    if isPendingDelivery {
      return "Pending delivery"
    }
    if isQueuedForWorker {
      return queuePolicy == .reassignWhenFree ? "Queued · reassignable" : "Queued"
    }
    return status.title
  }

  fileprivate var assignmentStateColor: Color {
    (isPendingDelivery || isQueuedForWorker)
      ? HarnessMonitorTheme.caution : taskStatusColor(for: status)
  }
}

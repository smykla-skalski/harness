import HarnessMonitorKit
import SwiftUI

#Preview("Task Board Lane Alignment") {
  TaskBoardLaneAlignmentPreviewSurface(
    textSizeIndex: HarnessMonitorTextSize.defaultIndex
  )
}

@MainActor
private struct TaskBoardLaneAlignmentPreviewSurface: View {
  let textSizeIndex: Int
  @State private var store: HarnessMonitorStore
  @State private var selectionModel = TaskBoardCardSelectionModel()
  @State private var revealCoordinator = TaskBoardLaneRevealCoordinator()
  @State private var dragRuntime = TaskBoardCardDragRuntime()
  @State private var nativeListCoordinator = TaskBoardNativeListCoordinator()

  init(textSizeIndex: Int) {
    self.textSizeIndex = textSizeIndex
    _store = State(
      initialValue: HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
    )
  }

  private var fontScale: CGFloat {
    HarnessMonitorTextSize.scale(at: textSizeIndex)
  }

  private var metrics: TaskBoardLaneMetrics {
    TaskBoardLaneMetrics(fontScale: fontScale)
  }

  private var previewDecision: Decision {
    Decision(
      id: "preview-lane-alignment",
      severity: .warn,
      ruleID: "preview-lane-alignment",
      sessionID: nil,
      agentID: nil,
      taskID: nil,
      summary: "Review the lane alignment",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
  }

  private var manuallyPlacedItem: TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "preview-manual-placement",
      title: "Keep manual placement metadata",
      body: "Placement metadata remains available to automation",
      status: .humanRequired,
      priority: .medium,
      tags: ["monitor"],
      projectId: "smykla-skalski/harness",
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      lanePosition: 0,
      laneOrigin: .manual(actor: "Harness Monitor"),
      laneSetAt: "2026-08-04T10:00:00Z",
      createdAt: "2026-08-04T09:00:00Z",
      updatedAt: "2026-08-04T10:00:00Z",
      deletedAt: nil
    )
  }

  var body: some View {
    TaskBoardLaneUnifiedColumn(
      lane: .humanRequired,
      apiItems: [manuallyPlacedItem],
      inboxItems: [],
      decisions: [previewDecision],
      apiCardPresentations: [:],
      inboxCardPresentations: [:],
      titleTypography: TaskBoardCardTitleTypography(fontScale: fontScale),
      isCollapsed: false,
      dragRuntime: dragRuntime,
      dropHighlightState: dragRuntime.highlightState(for: .humanRequired),
      nativeListCoordinator: nativeListCoordinator,
      cardGapModel: TaskBoardCardGapModel(),
      selectionModel: selectionModel,
      revealCoordinator: revealCoordinator,
      actions: TaskBoardOverviewActions(store: store, scope: .dashboard),
      onDrop: { _, _ in false },
      collapseOverridesRawValue: .constant(TaskBoardLaneCollapsePreferences.emptyRawValue)
    )
    .frame(
      width: metrics.laneWidth,
      height: metrics.laneFixedHeight,
      alignment: .topLeading
    )
    .padding(24)
    .frame(
      width: metrics.laneWidth + 48,
      height: metrics.laneFixedHeight + 48,
      alignment: .topLeading
    )
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    .environment(TaskBoardRelativeTimeClock())
  }
}

@MainActor
public enum TaskBoardLaneAlignmentPreviewRenderer {
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    return render(
      name: "task-board-lane-alignment-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "task-board-lane-alignment-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  private static func render(
    name: String,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let metrics = TaskBoardLaneMetrics(
      fontScale: HarnessMonitorTextSize.scale(at: textSizeIndex)
    )
    let content = TaskBoardLaneAlignmentPreviewSurface(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: content)
    let size = NSSize(
      width: metrics.laneWidth + 48,
      height: metrics.laneFixedHeight + 48
    )
    view.setFrameSize(size)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentView = view
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }

    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}

import AppKit
import HarnessMonitorKit
import SwiftUI

/// Shell snapshots for the add-a-task row pinned under a lane's cards.
public enum TaskBoardLaneQuickAddPreviewRenderer {
  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    let largestIndex = HarnessMonitorTextSize.scales.count - 1
    return render(name: "quick-add-closed", directory: directory) {
      TaskBoardLaneQuickAddPreviewColumn(lane: .todo)
    }
      && render(name: "quick-add-open", directory: directory) {
        TaskBoardLaneQuickAddPreviewColumn(lane: .todo, isOpen: true)
      }
      && render(name: "quick-add-typed", directory: directory) {
        TaskBoardLaneQuickAddPreviewColumn(
          lane: .todo,
          isOpen: true,
          draftTitle: "Cap the dispatch retry budget"
        )
      }
      && render(name: "quick-add-empty-lane", directory: directory) {
        TaskBoardLaneQuickAddPreviewColumn(lane: .planning)
      }
      // A lane whose colour is strong, where the field's tinted border has the
      // most to say.
      && render(name: "quick-add-coloured-lane", directory: directory) {
        TaskBoardLaneQuickAddPreviewColumn(lane: .inProgress, isOpen: true)
      }
      && render(name: "quick-add-umbrella-lane", directory: directory) {
        TaskBoardLaneQuickAddPreviewColumn(lane: .umbrella)
      }
      && render(name: "quick-add-light", directory: directory, themeMode: .light) {
        TaskBoardLaneQuickAddPreviewColumn(lane: .todo, isOpen: true)
      }
      && render(
        name: "quick-add-largest-text",
        directory: directory,
        size: NSSize(width: 560, height: 860),
        textSizeIndex: largestIndex
      ) {
        TaskBoardLaneQuickAddPreviewColumn(
          lane: .todo,
          isOpen: true,
          draftTitle: "Cap the dispatch retry budget"
        )
      }
  }

  @MainActor
  private static func render<Content: View>(
    name: String,
    directory: String,
    size: NSSize = NSSize(width: 480, height: 800),
    themeMode: HarnessMonitorThemeMode = .dark,
    textSizeIndex: Int = HarnessMonitorTextSize.defaultIndex,
    @ViewBuilder content: () -> Content
  ) -> Bool {
    let hosted =
      content()
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      // Stands in for the board's own chrome; without it the lane floats on a
      // transparent field and every secondary label reads as invisible.
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(themeMode: themeMode, textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    // Theme colors are asset-backed, so they resolve against the view's own
    // appearance and not the scene modifier alone.
    view.appearance = NSAppearance(named: themeMode == .light ? .aqua : .darkAqua)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()

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

/// The real lane column, so the row is judged where it ships rather than on
/// its own.
private struct TaskBoardLaneQuickAddPreviewColumn: View {
  let lane: TaskBoardInboxLane
  var isOpen = false
  var draftTitle = ""
  @State private var selectionModel = TaskBoardCardSelectionModel()
  @State private var revealCoordinator = TaskBoardLaneRevealCoordinator()
  @State private var dragRuntime = TaskBoardCardDragRuntime()
  @State private var nativeListCoordinator = TaskBoardNativeListCoordinator()

  /// Only there to make the board's create capability true; the cards below are
  /// local fixtures, because the store loads its own asynchronously and a
  /// synchronous render would catch an empty lane every time.
  @MainActor private static let store: HarnessMonitorStore = {
    HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
  }()

  private var items: [TaskBoardItem] {
    TaskBoardLaneQuickAddPreviewFixtures.items(in: lane)
  }

  var body: some View {
    TaskBoardLaneUnifiedColumn(
      lane: lane,
      apiItems: items,
      inboxItems: [],
      decisions: [],
      apiCardPresentations: [:],
      inboxCardPresentations: [:],
      titleTypography: TaskBoardCardTitleTypography(fontScale: 1),
      isCollapsed: false,
      dragRuntime: dragRuntime,
      dropHighlightState: dragRuntime.highlightState(for: lane),
      nativeListCoordinator: nativeListCoordinator,
      cardGapModel: TaskBoardCardGapModel(),
      selectionModel: selectionModel,
      revealCoordinator: revealCoordinator,
      actions: TaskBoardOverviewActions(store: Self.store, scope: .dashboard),
      onDrop: { _, _ in false },
      quickAddDraftTitle: draftTitle,
      collapseOverridesRawValue: .constant("")
    )
    .environment(TaskBoardRelativeTimeClock())
    .task {
      guard isOpen else { return }
      selectionModel.beginQuickAdd(in: lane)
    }
  }
}

private enum TaskBoardLaneQuickAddPreviewFixtures {
  /// The planning sample is deliberately left empty, to show the affordance
  /// under a lane with nothing in it.
  static func items(in lane: TaskBoardInboxLane) -> [TaskBoardItem] {
    guard let status = lane.taskBoardDropStatus, lane != .planning else { return [] }
    return [
      item(id: "quick-add-1", title: "Cap the dispatch retry budget", status: status, priority: .high),
      item(id: "quick-add-2", title: "Skip stale conflict no-ops", status: status, priority: .medium),
      item(id: "quick-add-3", title: "Let git reads reach the origin", status: status, priority: .low),
    ]
  }

  private static func item(
    id: String,
    title: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: "",
      status: status,
      priority: priority,
      tags: [],
      projectId: "smykla-skalski/harness",
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-27T09:00:00Z",
      updatedAt: "2026-07-27T09:05:00Z",
      deletedAt: nil
    )
  }
}

import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

private struct TaskBoardDispatchAppliedRowsPreview: View {
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    let fixture = TaskBoardDispatchAppliedRowsPreviewFixture.state
    ScrollView {
      TaskBoardOperationsDispatchCard(
        store: fixture.store,
        metrics: TaskBoardOverviewMetrics(fontScale: fontScale),
        dashboard: fixture.store.contentUI.dashboard,
        taskBoardItems: fixture.items,
        localHostProjectTypes: [],
        isActive: true
      )
      .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

@MainActor
private enum TaskBoardDispatchAppliedRowsPreviewFixture {
  static let state: (store: HarnessMonitorStore, items: [TaskBoardItem]) = {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
    let items = Array(store.globalTaskBoardItems.prefix(2))
    precondition(items.count == 2, "task-board dispatch preview requires two items")
    store.contentUI.dashboard.connectionState = .online
    store.contentUI.dashboard.taskBoardDispatchSummary = TaskBoardDispatchSummary(
      plans: [],
      applied: [
        decode(
          AppliedTaskPayload(
            boardItemId: items[0].id,
            sessionId: "session-release-build",
            workspaceId: nil,
            workingCopyId: nil,
            workItemId: "task-release-build",
            item: items[0]
          )
        ),
        decode(
          AppliedTaskPayload(
            boardItemId: items[1].id,
            sessionId: nil,
            workspaceId: "workspace-release-build",
            workingCopyId: "working-copy-release-build",
            workItemId: "task-sessionless-dispatch",
            item: items[1]
          )
        ),
      ]
    )
    return (store, items)
  }()

  private static func decode(_ payload: AppliedTaskPayload) -> TaskBoardDispatchAppliedTask {
    guard
      let data = try? JSONEncoder().encode(payload),
      let applied = try? JSONDecoder().decode(TaskBoardDispatchAppliedTask.self, from: data)
    else {
      preconditionFailure("task-board dispatch preview fixture must decode")
    }
    return applied
  }

  private struct AppliedTaskPayload: Encodable {
    let boardItemId: String
    let sessionId: String?
    let workspaceId: String?
    let workingCopyId: String?
    let workItemId: String
    let item: TaskBoardItem
  }
}

@MainActor
enum TaskBoardDispatchAppliedRowsPreviewRenderer {
  static func dump(toDirectory directory: String) -> Bool {
    render(
      name: "dispatch-applied-rows-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "dispatch-applied-rows-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  private static func render(
    name: String,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let height: CGFloat =
      textSizeIndex == HarnessMonitorTextSize.defaultIndex ? 540 : 620
    let content = TaskBoardDispatchAppliedRowsPreview()
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: content)
    view.setFrameSize(NSSize(width: 560, height: height))
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return failure("could not allocate a bitmap for \(name)")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return failure("could not encode \(name)")
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
      return failure("could not write \(name): \(error)")
    }
  }

  private static func failure(_ message: String) -> Bool {
    FileHandle.standardError.write(Data("dispatch applied rows preview: \(message)\n".utf8))
    return false
  }
}

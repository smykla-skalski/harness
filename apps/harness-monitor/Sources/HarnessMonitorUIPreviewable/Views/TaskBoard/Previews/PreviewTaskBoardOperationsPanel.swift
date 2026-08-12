import Foundation
import HarnessMonitorKit
import SwiftUI

#Preview("Operations - Loaded") {
  TaskBoardOperationsPreviewSurface(mode: .loaded)
    .padding(24)
    .frame(width: 1_320, height: 760, alignment: .topLeading)
    .harnessPreviewSceneAppearance()
}

#Preview("Operations - Empty") {
  TaskBoardOperationsPreviewSurface(mode: .empty)
    .padding(24)
    .frame(width: 1_320, alignment: .topLeading)
    .harnessPreviewSceneAppearance()
}

#Preview("Operations - Stacked") {
  TaskBoardOperationsPreviewSurface(mode: .loaded, layoutMode: .vertical)
    .padding(24)
    .frame(width: 540, height: 1_120, alignment: .topLeading)
    .harnessPreviewSceneAppearance()
}

#Preview("Operations - Largest Text") {
  TaskBoardOperationsPreviewSurface(mode: .loaded)
    .padding(24)
    .frame(width: 1_320, height: 860, alignment: .topLeading)
    .harnessPreviewSceneAppearance(textSizeIndex: 6)
}

@MainActor
private struct TaskBoardOperationsPreviewSurface: View {
  enum Mode {
    case loaded
    case empty
  }

  @State private var store: HarnessMonitorStore
  @State private var didSeedSummaries = false

  private let mode: Mode
  private let layoutMode: TaskBoardOperationsPanelLayoutMode

  init(
    mode: Mode,
    layoutMode: TaskBoardOperationsPanelLayoutMode = .responsive
  ) {
    self.mode = mode
    self.layoutMode = layoutMode
    _store = State(initialValue: Self.makeStore(mode: mode))
  }

  var body: some View {
    TaskBoardOperationsPanel(
      store: store,
      taskBoardItems: store.globalTaskBoardItems,
      layoutMode: layoutMode
    )
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .task {
      await seedSummariesIfNeeded()
    }
  }

  private static func makeStore(mode: Mode) -> HarnessMonitorStore {
    switch mode {
    case .loaded:
      HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
    case .empty:
      HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)
    }
  }

  private func seedSummariesIfNeeded() async {
    guard mode == .loaded, !didSeedSummaries else { return }
    didSeedSummaries = true

    await store.syncTaskBoard(
      request: TaskBoardSyncRequest(
        provider: .gitHub,
        direction: .both,
        dryRun: true
      )
    )
    store.globalTaskBoardSyncSummary = TaskBoardOperationsPreviewFixtures.syncSummary
    await store.dispatchTaskBoard(
      request: TaskBoardDispatchRequest(
        dryRun: true,
        projectDir: "/Users/example/Projects/harness",
        actor: "preview"
      )
    )
    await store.auditTaskBoard()
    await store.refreshTaskBoardProjects()
    await store.refreshTaskBoardMachines()
  }
}

@MainActor
public enum TaskBoardOperationsPanelPreviewRenderer {
  public static func dump(toDirectory directory: String) -> Bool {
    render(
      name: "operations-inspector-default",
      textSizeIndex: HarnessMonitorTextSize.defaultIndex,
      directory: directory
    )
      && render(
        name: "operations-inspector-largest-text",
        textSizeIndex: HarnessMonitorTextSize.scales.count - 1,
        directory: directory
      )
  }

  private static func render(
    name: String,
    textSizeIndex: Int,
    directory: String
  ) -> Bool {
    let content = TaskBoardOperationsPreviewSurface(
      mode: .loaded,
      layoutMode: .vertical
    )
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(width: 480, height: 1_800, alignment: .topLeading)
    .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: content)
    view.appearance = NSAppearance(named: .darkAqua)
    view.setFrameSize(NSSize(width: 480, height: 1_800))
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
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

private enum TaskBoardOperationsPreviewFixtures {
  static let syncSummary: TaskBoardSyncSummary = decode(
    TaskBoardSyncSummary.self,
    json: """
      {
        "total": 1,
        "providers": [
          {
            "provider": "github",
            "configured": true,
            "linked": 1,
            "pushable": 1,
            "blocked": 0,
            "tokenEnv": ["GITHUB_TOKEN"]
          }
        ],
        "operations": [
          {
            "provider": "github",
            "action": "push",
            "boardItemId": "preview-board-only",
            "externalId": null,
            "url": null,
            "dryRun": true,
            "applied": false
          }
        ]
      }
      """
  )

  private static let decoder = JSONDecoder()

  private static func decode<T: Decodable>(_ type: T.Type, json: String) -> T {
    do {
      return try decoder.decode(type, from: Data(json.utf8))
    } catch {
      fatalError("Failed to decode task-board operations preview fixture: \(error)")
    }
  }
}

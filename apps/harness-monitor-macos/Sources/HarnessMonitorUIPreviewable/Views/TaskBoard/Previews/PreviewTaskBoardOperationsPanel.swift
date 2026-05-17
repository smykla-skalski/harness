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
  TaskBoardOperationsPreviewSurface(mode: .loaded)
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

  init(mode: Mode) {
    self.mode = mode
    _store = State(initialValue: Self.makeStore(mode: mode))
  }

  var body: some View {
    TaskBoardOperationsPanel(
      store: store,
      taskBoardItems: store.globalTaskBoardItems
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

private enum TaskBoardOperationsPreviewFixtures {
  static let syncSummary: TaskBoardSyncSummary = decode(
    TaskBoardSyncSummary.self,
    json: """
      {
        "total": 1,
        "providers": [
          {
            "provider": "git_hub",
            "configured": true,
            "linked": 1,
            "pushable": 1,
            "blocked": 0,
            "tokenEnv": ["GITHUB_TOKEN"]
          }
        ],
        "operations": [
          {
            "provider": "git_hub",
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

  private static func decode<T: Decodable>(_ type: T.Type, json: String) -> T {
    do {
      return try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
      fatalError("Failed to decode task-board operations preview fixture: \(error)")
    }
  }
}

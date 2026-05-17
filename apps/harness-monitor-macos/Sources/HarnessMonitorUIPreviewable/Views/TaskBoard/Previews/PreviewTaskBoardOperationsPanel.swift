import HarnessMonitorKit
import SwiftUI

#Preview("Operations - Loaded") {
  TaskBoardOperationsPreviewSurface(mode: .loaded)
    .padding(24)
    .frame(width: 1_320, alignment: .topLeading)
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
    .frame(width: 540, alignment: .topLeading)
    .harnessPreviewSceneAppearance()
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
    ScrollView {
      TaskBoardOperationsPanel(
        store: store,
        taskBoardItems: store.globalTaskBoardItems
      )
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxHeight: 820, alignment: .topLeading)
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

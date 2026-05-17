import HarnessMonitorKit
import SwiftUI

/// Thin orchestrator: composes the Sync / Dispatch / Inventory cards in a
/// 3-column layout and resolves the local host's `project_types` once for
/// Dispatch's host-aware filter. Each card is its own `View` struct with
/// isolated `@State` so a change inside one card no longer invalidates
/// the other two during scroll - the structural lever that the live Time
/// Profiler trace 2026-05-16 surfaced as the cold-launch + scroll hot
/// path (see commits f364dc4d1, 65cac5448, 325db2264, this commit).
struct TaskBoardOperationsPanel: View {
  let store: HarnessMonitorStore
  let taskBoardItems: [TaskBoardItem]

  @Environment(\.fontScale)
  private var fontScale

  @State private var inventoryStatusChoice = TaskBoardStatusFilterChoice.all
  @State private var localHostProjectTypes: [String] = []

  private var metrics: TaskBoardOverviewMetrics {
    TaskBoardOverviewMetrics(fontScale: fontScale)
  }

  private var rowLabelFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var rowLabelWidth: CGFloat {
    112 * min(fontScale, 1.3)
  }

  private var dashboard: HarnessMonitorStore.ContentDashboardSlice {
    store.contentUI.dashboard
  }

  var body: some View {
    TaskBoardSection(title: "Operations") {
      TaskBoardOperationsPanelLayout(
        metrics: metrics,
        syncCard: TaskBoardOperationsSyncCard(
          store: store,
          metrics: metrics,
          dashboard: dashboard
        ),
        dispatchCard: TaskBoardOperationsDispatchCard(
          store: store,
          metrics: metrics,
          dashboard: dashboard,
          taskBoardItems: taskBoardItems,
          localHostProjectTypes: localHostProjectTypes
        ),
        inventoryCard: TaskBoardOperationsPanelInventoryCard(
          store: store,
          dashboard: dashboard,
          metrics: metrics,
          inventoryStatusChoice: $inventoryStatusChoice
        )
      )
      .font(rowLabelFont)
      .environment(\.taskBoardOperationsRowLabelFont, rowLabelFont)
      .environment(\.taskBoardOperationsRowLabelWidth, rowLabelWidth)
    }
    .task { await loadLocalHostProjectTypes() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.operations")
  }

  @MainActor
  private func loadLocalHostProjectTypes() async {
    do {
      let snapshot = try await store.taskBoardHostSnapshot()
      localHostProjectTypes = snapshot.local.projectTypes
    } catch {
      // Fail open: leave project types empty so dispatch shows every item.
      localHostProjectTypes = []
    }
  }
}

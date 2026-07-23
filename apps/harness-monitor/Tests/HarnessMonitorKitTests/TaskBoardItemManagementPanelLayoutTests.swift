import AppKit
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// The Manage Board Item sheet presents `TaskBoardItemManagementPanel` in a
/// fixed-width, non-resizable sheet (min 1_120, ideal 1_240) without any
/// horizontal scrolling. If the panel's minimum width exceeds the sheet
/// width, the ScrollView lays the whole form out wider than the window and
/// clips every field at the right edge - including the bottom action bar,
/// whose buttons then become unreachable.
@MainActor
@Suite("Task board item management panel layout")
struct TaskBoardItemManagementPanelLayoutTests {
  private static let sheetMinWidth: CGFloat = 1_120
  private static let sheetIdealWidth: CGFloat = 1_240

  @Test(
    "Panel minimum width stays within the sheet at the default and largest text sizes",
    arguments: [HarnessMonitorTextSize.defaultIndex, HarnessMonitorTextSize.scales.count - 1]
  )
  func panelMinimumWidthStaysWithinSheet(textSizeIndex: Int) {
    let minimumWidth = panelWidth(
      whenProposed: 1,
      textSizeIndex: textSizeIndex
    )

    #expect(minimumWidth <= Self.sheetMinWidth)
  }

  @Test(
    "Panel laid out at the sheet width does not overflow it",
    arguments: [1_120.0, 1_240.0]
  )
  func panelLaidOutAtSheetWidthDoesNotOverflow(sheetWidth: CGFloat) {
    let laidOutWidth = panelWidth(
      whenProposed: sheetWidth,
      textSizeIndex: HarnessMonitorTextSize.scales.count - 1
    )

    #expect(laidOutWidth <= sheetWidth)
  }

  /// Measures the width the panel reports for a given width proposal through
  /// the real SwiftUI layout engine: a tiny proposal surfaces the panel's
  /// minimum width, while a sheet-sized proposal surfaces the width the
  /// sheet's ScrollView would actually lay out and clip.
  private func panelWidth(
    whenProposed proposedWidth: CGFloat,
    textSizeIndex: Int
  ) -> CGFloat {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
    let panel = TaskBoardItemManagementPanel(
      item: sampleItem(),
      metrics: TaskBoardOverviewMetrics(
        fontScale: HarnessMonitorTextSize.scale(at: textSizeIndex)
      ),
      isActionInFlight: false,
      actions: TaskBoardOverviewActions(store: store, scope: .dashboard),
      evaluatePreviewState: TaskBoardEvaluatePreviewState(),
      selectionModel: TaskBoardCardSelectionModel(),
      backlink: .none,
      childrenSummary: nil
    )
    let host = NSHostingView(
      rootView: ManagementPanelWidthProbe(proposedWidth: proposedWidth) {
        panel
          .padding(HarnessMonitorTheme.spacingLG)
          .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
      }
    )
    host.frame = CGRect(x: 0, y: 0, width: 2_000, height: 2_000)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.width
  }

  private func sampleItem() -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-1",
      title: "Board item",
      body: "Body",
      status: .todo,
      priority: .high,
      tags: ["automation"],
      projectId: "project-1",
      targetProjectTypes: ["web"],
      agentMode: .interactive,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "451",
          url: "https://github.com/smykla-skalski/harness/issues/451"
        )
      ],
      planning: TaskBoardPlanningState(
        summary: "Approved plan",
        approvedBy: "lead",
        approvedAt: "2026-05-14T10:00:00Z"
      ),
      workflow: nil,
      sessionId: "sess-1",
      workItemId: "task-1",
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}

private struct ManagementPanelWidthProbe: Layout {
  let proposedWidth: CGFloat

  func sizeThatFits(
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    subviews.first?.sizeThatFits(
      ProposedViewSize(width: proposedWidth, height: nil)
    ) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    for subview in subviews {
      subview.place(
        at: bounds.origin,
        proposal: ProposedViewSize(width: proposedWidth, height: nil)
      )
    }
  }
}

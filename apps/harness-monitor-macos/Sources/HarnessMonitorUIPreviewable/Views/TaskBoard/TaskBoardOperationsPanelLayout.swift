import SwiftUI

struct TaskBoardOperationsPanelLayout<SyncCard: View, DispatchCard: View, InventoryCard: View>:
  View
{
  let metrics: TaskBoardOverviewMetrics
  let syncCard: SyncCard
  let dispatchCard: DispatchCard
  let inventoryCard: InventoryCard

  // Replaces `ViewThatFits`: width-gated if/else so only one branch lives in
  // the view tree at any time. `ViewThatFits` constructs BOTH candidate
  // subtrees (3 stateful Card views each) on every body update; during a
  // live AppKit resize that fires ~60 ticks/s, the AttributeGraph rebuild
  // dominated the main thread (alloc_page 10% in resize trace).
  @State private var fitsHorizontally = true

  private var horizontalMinWidth: CGFloat {
    metrics.operationsCardMinWidth * 3 + metrics.columnSpacing * 2
  }

  var body: some View {
    Group {
      if fitsHorizontally {
        HStack(alignment: .top, spacing: metrics.columnSpacing) {
          TaskBoardOperationsPanelColumn(
            minWidth: metrics.operationsCardMinWidth,
            content: syncCard
          )
          TaskBoardOperationsPanelColumn(
            minWidth: metrics.operationsCardMinWidth,
            content: dispatchCard
          )
          TaskBoardOperationsPanelColumn(
            minWidth: metrics.operationsCardMinWidth,
            content: inventoryCard
          )
        }
      } else {
        VStack(alignment: .leading, spacing: metrics.columnSpacing) {
          syncCard
          dispatchCard
          inventoryCard
        }
      }
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      let next = width >= horizontalMinWidth
      if fitsHorizontally != next {
        fitsHorizontally = next
      }
    }
  }
}

private struct TaskBoardOperationsPanelColumn<Content: View>: View {
  let minWidth: CGFloat
  let content: Content

  var body: some View {
    content
      .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .leading)
  }
}

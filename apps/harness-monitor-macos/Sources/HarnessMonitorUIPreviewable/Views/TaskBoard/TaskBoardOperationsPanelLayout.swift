import SwiftUI

struct TaskBoardOperationsPanelLayout<SyncCard: View, DispatchCard: View, InventoryCard: View>:
  View
{
  let metrics: TaskBoardOverviewMetrics
  let syncCard: SyncCard
  let dispatchCard: DispatchCard
  let inventoryCard: InventoryCard

  var body: some View {
    ViewThatFits(in: .horizontal) {
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
      VStack(alignment: .leading, spacing: metrics.columnSpacing) {
        syncCard
        dispatchCard
        inventoryCard
      }
    }
  }
}

private struct TaskBoardOperationsPanelColumn<Content: View>: View {
  let minWidth: CGFloat
  let content: Content

  var body: some View {
    content.frame(minWidth: minWidth, maxWidth: .infinity, alignment: .leading)
  }
}

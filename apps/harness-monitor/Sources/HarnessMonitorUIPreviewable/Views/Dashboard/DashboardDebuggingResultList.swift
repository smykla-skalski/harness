import HarnessMonitorKit
import SwiftUI

// Value-driven result list for the OCR debugging route. Receives its rows and
// highlight set as plain values plus a preview callback, so it lives outside
// the route view's @State-bearing file without reaching into private state.
struct DashboardDebuggingResultList: View {
  let items: [DashboardOCRImageItem]
  let highlightedItemIDs: Set<UUID>
  let onPreview: (DashboardOCRImageItem) -> Void

  var body: some View {
    if !items.isEmpty {
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(items) { item in
          DashboardOCRResultCard(
            item: item,
            isHighlighted: highlightedItemIDs.contains(item.id)
          ) {
            onPreview(item)
          }
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRResultList)
    }
  }
}

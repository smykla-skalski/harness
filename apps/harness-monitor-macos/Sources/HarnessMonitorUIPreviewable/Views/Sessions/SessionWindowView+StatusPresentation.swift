import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  var sessionStatusSummaryModel: SessionStatusSummaryModel {
    let metrics = store.connectionMetrics
    let sourceTitle: String =
      if snapshot == nil {
        "Loading"
      } else if isLoading || snapshot?.source == nil {
        "Refreshing"
      } else {
        snapshot?.source.rawValue.capitalized ?? "Loading"
      }
    let sourceTint: SessionStatusSourceTint =
      if isLoading || snapshot?.source == nil {
        .tertiary
      } else {
        switch snapshot?.source {
        case .live:
          harnessSidebarStatusSourceTint(for: metrics)
        case .cache:
          harnessSidebarStatusSourceTint(for: metrics)
        case .catalog:
          .tertiary
        case .none:
          .tertiary
        }
      }
    return SessionStatusSummaryModel(
      metrics: metrics,
      sourceTitle: sourceTitle,
      sourceSystemImage: sourceSystemImage,
      sourceTint: sourceTint,
      statusStripState: harnessSidebarStatusStripState(
        for: store,
        isMCPRegistryHostEnabled: mcpRegistryHostEnabled
      ),
      connectionSummaryText: harnessSidebarConnectionSummaryText(for: store),
      sessionStatusTitle: summary?.status.title ?? "Loading"
    )
  }

  var sourceSystemImage: String {
    guard !isLoading, let source = snapshot?.source else {
      return "arrow.clockwise"
    }
    switch source {
    case .live:
      return "bolt.horizontal.circle"
    case .cache:
      return "externaldrive"
    case .catalog:
      return "square.stack.3d.up"
    }
  }
}

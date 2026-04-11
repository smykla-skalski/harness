import HarnessMonitorKit
import SwiftUI

private struct HarnessMonitorSheetMetrics {
  let minWidth: CGFloat
  let idealWidth: CGFloat
  let minHeight: CGFloat

  static func metrics(for sheet: HarnessMonitorStore.PresentedSheet) -> Self {
    switch sheet {
    case .sendSignal:
      Self(minWidth: 420, idealWidth: 500, minHeight: 300)
    case .codexFlow:
      Self(minWidth: 520, idealWidth: 620, minHeight: 520)
    case .agentTui:
      Self(minWidth: 860, idealWidth: 980, minHeight: 620)
    }
  }
}

struct HarnessMonitorSheetRouter: View {
  let store: HarnessMonitorStore
  let sheet: HarnessMonitorStore.PresentedSheet

  var body: some View {
    sheetContent
      .frame(
        minWidth: metrics.minWidth,
        idealWidth: metrics.idealWidth,
        minHeight: metrics.minHeight
      )
  }

  @ViewBuilder
  private var sheetContent: some View {
    switch sheet {
    case .agentTui:
      AgentTuiSheetView(store: store)
    case .codexFlow:
      CodexFlowSheetView(store: store)
    case .sendSignal(let agentID):
      SendSignalSheetView(store: store, agentID: agentID)
    }
  }

  private var metrics: HarnessMonitorSheetMetrics {
    .metrics(for: sheet)
  }
}

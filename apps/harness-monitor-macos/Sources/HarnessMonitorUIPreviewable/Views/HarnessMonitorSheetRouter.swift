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
    case .newSession:
      Self(minWidth: 480, idealWidth: 560, minHeight: 360)
    }
  }
}

struct HarnessMonitorSheetRouter: View {
  let store: HarnessMonitorStore
  let sheet: HarnessMonitorStore.PresentedSheet
  @State private var newSessionViewModel: NewSessionViewModel?

  var body: some View {
    sheetContent
      .frame(
        minWidth: metrics.minWidth,
        idealWidth: metrics.idealWidth,
        minHeight: metrics.minHeight
      )
      .onAppear {
        if case .newSession = sheet, newSessionViewModel == nil {
          newSessionViewModel = store.makeNewSessionViewModel()
        }
      }
  }

  @ViewBuilder private var sheetContent: some View {
    switch sheet {
    case .sendSignal(let agentID):
      SendSignalSheetView(store: store, agentID: agentID)
    case .newSession:
      if let viewModel = newSessionViewModel {
        NewSessionSheetView(store: store, viewModel: viewModel)
      }
    }
  }

  private var metrics: HarnessMonitorSheetMetrics {
    .metrics(for: sheet)
  }
}

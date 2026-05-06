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
    case .attachExternal:
      Self(minWidth: 480, idealWidth: 560, minHeight: 360)
    case .signalDetail:
      Self(minWidth: 460, idealWidth: 560, minHeight: 420)
    case .createTask:
      Self(minWidth: 480, idealWidth: 560, minHeight: 420)
    case .taskActions:
      Self(minWidth: 520, idealWidth: 620, minHeight: 560)
    case .leaderTransfer:
      Self(minWidth: 460, idealWidth: 540, minHeight: 420)
    }
  }
}

@MainActor
struct HarnessMonitorSheetRouter: View {
  let store: HarnessMonitorStore
  let sheet: HarnessMonitorStore.PresentedSheet
  @State private var newSessionViewModel: NewSessionViewModel?

  init(store: HarnessMonitorStore, sheet: HarnessMonitorStore.PresentedSheet) {
    self.store = store
    self.sheet = sheet
    if case .newSession = sheet {
      _newSessionViewModel = State(initialValue: store.makeNewSessionViewModel())
    } else {
      _newSessionViewModel = State(initialValue: nil)
    }
  }

  var body: some View {
    sheetContent
      .frame(
        minWidth: metrics.minWidth,
        idealWidth: metrics.idealWidth,
        minHeight: metrics.minHeight
      )
  }

  @ViewBuilder private var sheetContent: some View {
    switch sheet {
    case .sendSignal(let agentID):
      SendSignalSheetView(store: store, agentID: agentID)
    case .newSession:
      if let viewModel = newSessionViewModel {
        NewSessionSheetView(store: store, viewModel: viewModel)
      } else {
        NewSessionOfflinePlaceholder(store: store)
      }
    case .attachExternal(let bookmarkID, let preview):
      AttachSessionSheetView(store: store, bookmarkID: bookmarkID, preview: preview)
    case .signalDetail(let signalID):
      SignalDetailSheet(store: store, signalID: signalID)
    case .createTask(let sessionID):
      CreateTaskSheet(store: store, sessionID: sessionID)
    case .taskActions(let sessionID, let taskID):
      TaskActionsSheet(store: store, sessionID: sessionID, taskID: taskID)
    case .leaderTransfer(let sessionID):
      LeaderTransferSheet(store: store, sessionID: sessionID)
    }
  }

  private var metrics: HarnessMonitorSheetMetrics {
    .metrics(for: sheet)
  }
}

private struct NewSessionOfflinePlaceholder: View {
  let store: HarnessMonitorStore

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "network.slash")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Harness daemon not connected.")
        .font(.headline)
      Text("Start the daemon and try again.")
        .foregroundStyle(.secondary)
      Button("Dismiss") {
        store.dismissSheet()
      }
      .keyboardShortcut(.cancelAction)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

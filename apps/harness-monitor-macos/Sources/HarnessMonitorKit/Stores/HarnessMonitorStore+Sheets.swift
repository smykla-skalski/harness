import Foundation

extension HarnessMonitorStore {
  public func presentCodexFlowSheet() {
    guard guardSessionActionsAvailable() else { return }
    guard selectedSessionID != nil else { return }
    presentedSheet = .codexFlow
  }

  public func presentSendSignalSheet(agentID: String) {
    guard guardSessionActionsAvailable() else { return }
    guard selectedSessionID != nil else { return }
    presentedSheet = .sendSignal(agentID: agentID)
  }

  public func dismissSheet() {
    presentedSheet = nil
  }
}

import Foundation

extension HarnessMonitorStore {
  public var isCodexFlowAvailable: Bool {
    false
  }

  public func presentCodexFlowSheet() {
    guard isCodexFlowAvailable else { return }
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

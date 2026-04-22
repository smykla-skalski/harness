import Foundation

extension HarnessMonitorStore {
  public func requestAgentsWindowSelection(_ selection: AgentTuiSheetSelection) {
    pendingAgentsWindowSelection = selection
  }

  public func consumePendingAgentsWindowSelection() -> AgentTuiSheetSelection? {
    let next = pendingAgentsWindowSelection
    pendingAgentsWindowSelection = nil
    return next
  }
}

import Foundation

extension HarnessMonitorStore {
  public func requestWorkspaceSelection(_ selection: WorkspaceSelection) {
    pendingWorkspaceSelection = selection
  }

  public func consumePendingWorkspaceSelection() -> WorkspaceSelection? {
    let next = pendingWorkspaceSelection
    pendingWorkspaceSelection = nil
    return next
  }

  public func requestAgentsWindowSelection(_ selection: WorkspaceSelection) {
    requestWorkspaceSelection(selection)
  }

  public func consumePendingAgentsWindowSelection() -> WorkspaceSelection? {
    consumePendingWorkspaceSelection()
  }
}

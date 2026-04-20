import Foundation

extension HarnessMonitorStore {
  public func presentSendSignalSheet(agentID: String) {
    guard guardSessionActionsAvailable() else { return }
    guard selectedSessionID != nil else { return }
    presentedSheet = .sendSignal(agentID: agentID)
  }

  public func dismissSheet() {
    presentedSheet = nil
  }

  public func makeNewSessionViewModel() -> NewSessionViewModel {
    let resolvedBookmarkStore = bookmarkStore
      ?? BookmarkStore(containerURL: FileManager.default.temporaryDirectory)
    let resolvedClient: any HarnessMonitorClientProtocol = client
      ?? HarnessMonitorAPIClient(
        connection: HarnessMonitorConnection(
          endpoint: URL(string: "http://127.0.0.1:0")!,
          token: ""
        )
      )
    return NewSessionViewModel(
      store: self,
      bookmarkStore: resolvedBookmarkStore,
      client: resolvedClient
    )
  }
}

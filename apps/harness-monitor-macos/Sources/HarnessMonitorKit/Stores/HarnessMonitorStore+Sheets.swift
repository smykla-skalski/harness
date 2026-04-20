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
    let resolvedBookmarkStore: BookmarkStore
    if let store = bookmarkStore {
      resolvedBookmarkStore = store
    } else {
      HarnessMonitorLogger.store.warning(
        "bookmarkStore is nil; falling back to temporaryDirectory — bookmark persistence will not work"
      )
      resolvedBookmarkStore = BookmarkStore(containerURL: FileManager.default.temporaryDirectory)
    }
    let resolvedClient: any HarnessMonitorClientProtocol
    if let apiClient = client {
      resolvedClient = apiClient
    } else {
      HarnessMonitorLogger.store.warning(
        "client is nil; falling back to stub — submit() will fail until a real connection is established"
      )
      resolvedClient = HarnessMonitorAPIClient(
        connection: HarnessMonitorConnection(
          endpoint: URL(string: "http://127.0.0.1:0")!,
          token: ""
        )
      )
    }
    return NewSessionViewModel(
      store: self,
      bookmarkStore: resolvedBookmarkStore,
      client: resolvedClient
    )
  }
}

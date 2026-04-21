import Foundation

extension HarnessMonitorStore {
  public func adoptExternalSession(
    bookmarkID: String,
    preview: SessionDiscoveryProbe.Preview
  ) async {
    guard let client else {
      presentFailureFeedback("Daemon client unavailable.")
      return
    }
    do {
      let summary = try await client.adoptSession(
        bookmarkID: bookmarkID,
        sessionRoot: preview.sessionRoot
      )
      HarnessMonitorLogger.store.info(
        "adopted external session \(summary.sessionId, privacy: .public)"
      )
      await refresh()
      dismissSheet()
    } catch let apiError as HarnessMonitorAPIError {
      presentFailureFeedback(apiError.errorDescription ?? "Adopt failed.")
    } catch {
      presentFailureFeedback("Adopt failed: \(error.localizedDescription)")
    }
  }

  public func presentSendSignalSheet(agentID: String) {
    guard guardSessionActionsAvailable() else { return }
    guard selectedSessionID != nil else { return }
    presentedSheet = .sendSignal(agentID: agentID)
  }

  public func dismissSheet() {
    presentedSheet = nil
  }

  public func makeNewSessionViewModel() -> NewSessionViewModel? {
    guard let bookmarkStore else {
      HarnessMonitorLogger.store.warning(
        "bookmarkStore is nil; cannot present New Session sheet"
      )
      return nil
    }
    guard let client else {
      HarnessMonitorLogger.store.warning(
        "client is nil; cannot present New Session sheet"
      )
      return nil
    }
    return NewSessionViewModel(
      store: self,
      bookmarkStore: bookmarkStore,
      client: client
    )
  }
}

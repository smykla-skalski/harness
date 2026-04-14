import Foundation

extension HarnessMonitorStore {
  func previewReadySessionID(
    client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) -> String? {
    guard
      selectedSessionID == nil,
      let previewClient = client as? PreviewHarnessClient,
      let readySessionID = previewClient.readySessionID,
      sessions.contains(where: { $0.sessionId == readySessionID })
    else {
      return nil
    }

    return readySessionID
  }

  @discardableResult
  public func presentSuccessFeedback(_ message: String) -> UUID {
    toast.presentSuccess(message)
  }

  @discardableResult
  public func presentFailureFeedback(_ message: String) -> UUID {
    toast.presentFailure(message)
  }

  public func dismissFeedback(id: UUID) {
    toast.dismiss(id: id)
  }
}

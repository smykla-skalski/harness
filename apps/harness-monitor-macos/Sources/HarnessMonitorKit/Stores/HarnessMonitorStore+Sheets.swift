import Foundation

extension HarnessMonitorStore {
  public func requestCreateTaskSheet() {
    let actionName = "Create task"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return }
    presentedSheet = .createTask(sessionID: action.sessionID)
  }

  public func requestEndSelectedSessionConfirmation() {
    requestEndSelectedSessionConfirmation(actor: "harness-app")
  }

  func requestEndSelectedSessionConfirmation(actor: String) {
    let actionName = "End session"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return }
    let actorID = controlPlaneActionActor(for: actor)
    pendingConfirmation = .endSession(sessionID: action.sessionID, actorID: actorID)
  }

  public func adoptExternalSession(
    bookmarkID: String,
    preview: SessionDiscoveryProbe.Preview
  ) async {
    guard let client else {
      let message = "Daemon client unavailable."
      recordExternalSessionAttachOutcome(message: message, succeeded: false)
      presentFailureFeedback(message)
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
      let message = "Attached session \(summary.sessionId)."
      recordExternalSessionAttachOutcome(message: message, succeeded: true)
      dismissSheet()
      await refresh(using: client, preserveSelection: false)
      await selectSession(summary.sessionId)
      presentSuccessFeedback(message)
    } catch let apiError as HarnessMonitorAPIError {
      let message = apiError.errorDescription ?? "Adopt failed."
      recordExternalSessionAttachOutcome(message: message, succeeded: false)
      presentFailureFeedback(message)
    } catch {
      let message = "Adopt failed: \(error.localizedDescription)"
      recordExternalSessionAttachOutcome(message: message, succeeded: false)
      presentFailureFeedback(message)
    }
  }

  public func presentSendSignalSheet(agentID: String) {
    let actionName = "Send signal"
    guard prepareSelectedSessionAction(named: actionName) != nil else { return }
    guard actionActor(for: "harness-app", actionName: actionName) != nil else { return }
    presentedSheet = .sendSignal(agentID: agentID)
  }

  public func dismissSheet() {
    presentedSheet = nil
  }

  public func cancelConfirmation() {
    pendingConfirmation = nil
  }

  public func confirmPendingAction() async {
    guard !isSessionReadOnly else {
      pendingConfirmation = nil
      reportUnavailableSelectedSessionAction(
        "Confirm pending action",
        message: readOnlySessionAccessMessage
      )
      return
    }
    guard let pendingConfirmation else {
      return
    }
    self.pendingConfirmation = nil

    switch pendingConfirmation {
    case .endSession(_, let actorID):
      await endSelectedSession(actor: actorID)
    case .removeAgent(_, let agentID, let actorID):
      await removeAgent(agentID: agentID, actor: actorID)
    }
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

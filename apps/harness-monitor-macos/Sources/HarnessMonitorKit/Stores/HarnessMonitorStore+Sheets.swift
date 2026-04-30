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

  public func confirmationSessionSubject(sessionID: String) -> String {
    let sessionTitle: String?
    if selectedSession?.session.sessionId == sessionID {
      sessionTitle = selectedSession?.session.title
    } else {
      sessionTitle = sessionIndex.sessionSummary(for: sessionID)?.title
    }
    return confirmationSubject(sessionTitle, fallback: "the selected session")
  }

  public func confirmationAgentSubject(sessionID: String, agentID: String) -> String {
    let agentName: String? = if selectedSession?.session.sessionId == sessionID {
      selectedSession?.agents.first(where: { $0.agentId == agentID })?.name
    } else {
      nil
    }
    return confirmationSubject(agentName, fallback: "this agent")
  }

  private func confirmationSubject(_ value: String?, fallback: String) -> String {
    guard let value else {
      return fallback
    }
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else {
      return fallback
    }
    return "\"\(trimmedValue)\""
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
    case .endSession(let sessionID, let actorID):
      _ = await endSession(sessionID: sessionID, actorID: actorID)
    case .removeAgent(let sessionID, let agentID, let actorID):
      _ = await removeAgent(sessionID: sessionID, agentID: agentID, actorID: actorID)
    case .interruptCodexRun(let sessionID, let runID, _):
      _ = await interruptCodexRun(sessionID: sessionID, runID: runID)
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

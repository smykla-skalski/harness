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
    let agentName: String? =
      if selectedSession?.session.sessionId == sessionID {
        selectedSession?.agents.first(where: { $0.agentId == agentID })?.name
      } else {
        nil
      }
    return confirmationSubject(agentName, fallback: "this agent")
  }

  public func confirmationTaskSubject(taskTitle: String) -> String {
    confirmationSubject(taskTitle, fallback: "this task")
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

  public func presentSendSignalSheetForSelectedSessionLeader() {
    guard let detail = selectedSession else { return }
    let leaderID =
      detail.session.leaderId.flatMap { id in
        detail.agents.contains(where: { $0.agentId == id }) ? id : nil
      } ?? detail.agents.first?.agentId
    guard let agentID = leaderID else { return }
    presentSendSignalSheet(agentID: agentID)
  }

  public func dismissSheet() {
    presentedSheet = nil
  }

  public func cancelConfirmation() {
    HarnessMonitorUITestTrace.record(
      component: "store.confirmation",
      event: "cancelled",
      details: [
        "pending_confirmation": pendingConfirmation?.uiTestTraceLabel ?? "nil"
      ]
    )
    pendingConfirmation = nil
  }

  public func confirmPendingAction() async {
    HarnessMonitorUITestTrace.record(
      component: "store.confirmation",
      event: "confirm-current",
      details: [
        "pending_confirmation": pendingConfirmation?.uiTestTraceLabel ?? "nil",
        "is_session_read_only": String(isSessionReadOnly),
      ]
    )
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
    await confirmPendingAction(pendingConfirmation)
  }

  public func confirmPendingAction(_ pendingConfirmation: PendingConfirmation) async {
    HarnessMonitorUITestTrace.record(
      component: "store.confirmation",
      event: "confirm-captured",
      details: [
        "captured_confirmation": pendingConfirmation.uiTestTraceLabel,
        "store_pending_confirmation": self.pendingConfirmation?.uiTestTraceLabel ?? "nil",
        "is_session_read_only": String(isSessionReadOnly),
      ]
    )
    guard !isSessionReadOnly else {
      if self.pendingConfirmation == pendingConfirmation {
        self.pendingConfirmation = nil
      }
      reportUnavailableSelectedSessionAction(
        "Confirm pending action",
        message: readOnlySessionAccessMessage
      )
      return
    }
    if self.pendingConfirmation == pendingConfirmation {
      HarnessMonitorUITestTrace.record(
        component: "store.confirmation",
        event: "clearing-store-pending",
        details: ["captured_confirmation": pendingConfirmation.uiTestTraceLabel]
      )
      self.pendingConfirmation = nil
    }

    if await handlePendingSessionConfirmation(pendingConfirmation) {
      return
    }
    if await handlePendingTaskConfirmation(pendingConfirmation) {
      return
    }
    await handlePendingAgentConfirmation(pendingConfirmation)
  }

  private func handlePendingSessionConfirmation(
    _ pendingConfirmation: PendingConfirmation
  ) async -> Bool {
    switch pendingConfirmation {
    case .endSession(let sessionID, let actorID):
      _ = await endSession(sessionID: sessionID, actorID: actorID)
    case .removeSession(let sessionID, let actorID):
      HarnessMonitorUITestTrace.record(
        component: "store.confirmation",
        event: "dispatch-remove-session",
        details: ["session_id": sessionID]
      )
      _ = await removeSession(sessionID: sessionID, actorID: actorID)
    case .removeSessions(let sessionIDs, let actorID):
      HarnessMonitorUITestTrace.record(
        component: "store.confirmation",
        event: "dispatch-remove-sessions",
        details: [
          "session_count": String(sessionIDs.count),
          "session_ids": sessionIDs.joined(separator: ","),
        ]
      )
      _ = await removeSessions(sessionIDs: sessionIDs, actorID: actorID)
    default:
      return false
    }
    return true
  }

  private func handlePendingTaskConfirmation(
    _ pendingConfirmation: PendingConfirmation
  ) async -> Bool {
    switch pendingConfirmation {
    case .deleteTask(let sessionID, let taskID, _, let actorID, let noteCount):
      _ = await deleteTask(
        sessionID: sessionID,
        taskID: taskID,
        actorID: actorID,
        expectedNoteCount: noteCount
      )
    case .deleteTasks(let sessionID, let taskIDs, let actorID):
      HarnessMonitorUITestTrace.record(
        component: "store.confirmation",
        event: "dispatch-delete-tasks",
        details: [
          "task_count": String(taskIDs.count),
          "task_ids": taskIDs.joined(separator: ","),
        ]
      )
      _ = await deleteTasks(sessionID: sessionID, taskIDs: taskIDs, actorID: actorID)
    default:
      return false
    }
    return true
  }

  private func handlePendingAgentConfirmation(
    _ pendingConfirmation: PendingConfirmation
  ) async {
    switch pendingConfirmation {
    case .removeAgent(let sessionID, let agentID, let actorID):
      _ = await removeAgent(sessionID: sessionID, agentID: agentID, actorID: actorID)
    case .removeAgents(let sessionID, let agentIDs, let actorID):
      HarnessMonitorUITestTrace.record(
        component: "store.confirmation",
        event: "dispatch-remove-agents",
        details: [
          "agent_count": String(agentIDs.count),
          "agent_ids": agentIDs.joined(separator: ","),
        ]
      )
      _ = await removeAgents(sessionID: sessionID, agentIDs: agentIDs, actorID: actorID)
    case .interruptCodexRun(let sessionID, let runID, _):
      _ = await interruptCodexRun(sessionID: sessionID, runID: runID)
    default:
      break
    }
  }

  public func makeNewSessionViewModel() -> NewSessionViewModel? {
    guard let bookmarkStore else {
      HarnessMonitorLogger.store.warning(
        "bookmarkStore is nil; cannot present New Session sheet"
      )
      return nil
    }
    return NewSessionViewModel(
      store: self,
      bookmarkStore: bookmarkStore
    )
  }
}

import AppKit
import Foundation

extension HarnessMonitorStore {
  public var selectedSessionBookmarkTitle: String {
    guard isPersistenceAvailable else { return "Bookmarks Unavailable" }
    guard let sessionID = selectedSessionID else { return "Bookmark Session" }
    return isBookmarked(sessionId: sessionID) ? "Remove Bookmark" : "Bookmark Session"
  }

  public func toggleSelectedSessionBookmark() {
    guard let sessionID = selectedSessionID else { return }
    let projectID =
      selectedSession?.session.projectId
      ?? sessions.first(where: { $0.sessionId == sessionID })?.projectId
      ?? ""
    toggleBookmark(sessionId: sessionID, projectId: projectID)
  }

  public func copySelectedItemID() {
    let text: String
    switch inspectorSelection {
    case .task(let taskID): text = taskID
    case .signal(let signalID): text = signalID
    case .observer:
      text = selectedSession?.observer?.observeId ?? selectedSessionID ?? ""
    case .none:
      text = selectedSessionID ?? ""
    }
    guard !text.isEmpty else { return }
    #if canImport(AppKit)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #endif
  }

  func synchronizeActionActor() {
    let agents = selectedSession?.agents ?? []
    let available = availableActionActors
    if agents.contains(where: { $0.agentId == actionActorID }) {
      return
    }
    if let leaderID = selectedSession?.session.leaderId,
      agents.contains(where: { $0.agentId == leaderID })
    {
      actionActorID = leaderID
    } else {
      actionActorID = available.first?.agentId
    }
  }

  func resolvedActionActor() -> String? {
    let agents = selectedSession?.agents ?? []
    if let actionActorID, !actionActorID.isEmpty,
      agents.contains(where: { $0.agentId == actionActorID })
    {
      return actionActorID
    }
    if let leaderID = selectedSession?.session.leaderId, !leaderID.isEmpty,
      agents.contains(where: { $0.agentId == leaderID })
    {
      return leaderID
    }
    return availableActionActors.first?.agentId
  }

  func synchronizeSessionBaggage(for sessionID: String?) {
    guard let sessionID else {
      HarnessMonitorTelemetry.shared.clearSessionBaggage()
      return
    }

    let projectID =
      sessionIndex.sessionSummary(for: sessionID)?.projectId
      ?? selectedSession.flatMap { session in
        session.session.sessionId == sessionID ? session.session.projectId : nil
      }
      ?? sessions.first(where: { $0.sessionId == sessionID })?.projectId
    HarnessMonitorTelemetry.shared.setSessionBaggage(sessionID: sessionID, projectID: projectID)
  }

  func beginSessionLoad() -> UInt64 {
    sessionLoadSequence &+= 1
    withUISyncBatch {
      activeSessionLoadRequest = sessionLoadSequence
      if selectedSession == nil {
        isSelectionLoading = true
      }
    }
    return sessionLoadSequence
  }

  @discardableResult
  func startSessionLoad(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    requestID: UInt64
  ) -> Task<Void, Never> {
    cancelSessionLoad()
    sessionLoadTaskToken &+= 1
    let token = sessionLoadTaskToken
    let task = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        if self.sessionLoadTaskToken == token {
          self.sessionLoadTask = nil
        }
      }
      await self.loadSession(using: client, sessionID: sessionID, requestID: requestID)
      guard !Task.isCancelled else {
        return
      }
      guard self.isCurrentSessionLoad(requestID, sessionID: sessionID) else {
        return
      }
      self.ensureSelectedSessionStream(using: client, sessionID: sessionID)
    }
    sessionLoadTask = task
    return task
  }

  private func ensureSelectedSessionStream(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) {
    guard selectedSessionID == sessionID else {
      return
    }
    let expectedSubscriptions = Set([sessionID])
    guard sessionStreamTask == nil || subscribedSessionIDs != expectedSubscriptions else {
      return
    }
    startSessionStream(using: client, sessionID: sessionID)
  }
}

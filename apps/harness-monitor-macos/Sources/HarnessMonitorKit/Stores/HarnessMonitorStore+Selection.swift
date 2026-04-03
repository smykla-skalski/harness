import AppKit
import Foundation

extension HarnessMonitorStore {
  public var selectedSessionID: String? {
    get { selection.selectedSessionID }
    set { selection.selectedSessionID = newValue }
  }

  public var selectedSession: SessionDetail? {
    get { selection.selectedSession }
    set { selection.selectedSession = newValue }
  }

  public var timeline: [TimelineEntry] {
    get { selection.timeline }
    set { selection.timeline = newValue }
  }

  public var inspectorSelection: InspectorSelection {
    get { selection.inspectorSelection }
    set { selection.inspectorSelection = newValue }
  }

  public var actionActorID: String? {
    get { selection.actionActorID }
    set { selection.actionActorID = newValue }
  }

  public var selectedActionActorID: String {
    get { resolvedActionActor() ?? "" }
    set { actionActorID = newValue.isEmpty ? nil : newValue }
  }

  public var isSelectionLoading: Bool {
    get { selection.isSelectionLoading }
    set { selection.isSelectionLoading = newValue }
  }

  public var isSessionActionInFlight: Bool {
    get { selection.isSessionActionInFlight }
    set { selection.isSessionActionInFlight = newValue }
  }

  // MARK: - Navigation history

  public var canNavigateBack: Bool {
    !navigationBackStack.isEmpty
  }

  public var canNavigateForward: Bool {
    !navigationForwardStack.isEmpty
  }

  public func navigateBack() async {
    guard !navigationBackStack.isEmpty else { return }
    let destination = navigationBackStack.removeLast()
    navigationForwardStack.append(selectedSessionID)
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    await loadSessionWithoutHistory(destination)
  }

  public func navigateForward() async {
    guard !navigationForwardStack.isEmpty else { return }
    let destination = navigationForwardStack.removeLast()
    navigationBackStack.append(selectedSessionID)
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    await loadSessionWithoutHistory(destination)
  }

  private func recordNavigation(to sessionID: String?) {
    guard !isNavigatingHistory else { return }
    guard selectedSessionID != sessionID else { return }
    navigationBackStack.append(selectedSessionID)
    navigationForwardStack.removeAll()
  }

  private func loadSessionWithoutHistory(_ sessionID: String?) async {
    let previousProjectId = selectedSessionSummary?.projectId
    primeSessionSelection(sessionID)
    guard let sessionID else {
      stopSessionStream()
      return
    }

    guard connectionState == .online, let client else {
      restorePersistedSessionSelection(sessionID: sessionID)
      stopSessionStream()
      return
    }

    let newProjectId = sessions.first(where: { $0.sessionId == sessionID })?.projectId
    if let previousProjectId, let newProjectId, newProjectId != previousProjectId {
      saveFilterPreference(for: previousProjectId)
      loadFilterPreference(for: newProjectId)
    }

    let requestID = beginSessionLoad()
    await loadSession(using: client, sessionID: sessionID, requestID: requestID)
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }
    startSessionStream(using: client, sessionID: sessionID)
  }

  // MARK: - Selection

  public func primeSessionSelection(_ sessionID: String?) {
    recordNavigation(to: sessionID)
    cancelSessionPushFallback()
    selectedSessionID = sessionID
    inspectorSelection = .none
    lastError = nil

    guard let sessionID else {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
      selectedSession = nil
      timeline = []
      stopSessionStream()
      return
    }

    guard selectedSession?.session.sessionId != sessionID else {
      return
    }

    isSelectionLoading = true
    selectedSession = nil
    timeline = []
  }

  public func selectSession(_ sessionID: String?) async {
    let previousProjectId = selectedSessionSummary?.projectId
    primeSessionSelection(sessionID)
    guard let sessionID else {
      stopSessionStream()
      return
    }

    guard connectionState == .online, let client else {
      restorePersistedSessionSelection(sessionID: sessionID)
      stopSessionStream()
      return
    }

    let newProjectId = sessions.first(where: { $0.sessionId == sessionID })?.projectId
    if let previousProjectId, let newProjectId, newProjectId != previousProjectId {
      saveFilterPreference(for: previousProjectId)
      loadFilterPreference(for: newProjectId)
    }

    let requestID = beginSessionLoad()
    await loadSession(using: client, sessionID: sessionID, requestID: requestID)
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else {
      return
    }
    startSessionStream(using: client, sessionID: sessionID)
  }

  public func inspect(taskID: String) {
    inspectorSelection = .task(taskID)
  }

  public func inspect(agentID: String) {
    inspectorSelection = .agent(agentID)
  }

  public func inspect(signalID: String) {
    inspectorSelection = .signal(signalID)
  }

  public func inspectObserver() {
    inspectorSelection = .observer
  }

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
    case .agent(let agentID): text = agentID
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
    let available = availableActionActors
    if available.contains(where: { $0.agentId == actionActorID }) {
      return
    }
    actionActorID = selectedSession?.session.leaderId ?? available.first?.agentId
  }

  func resolvedActionActor() -> String? {
    if let actionActorID, !actionActorID.isEmpty {
      return actionActorID
    }
    if let leaderID = selectedSession?.session.leaderId, !leaderID.isEmpty {
      return leaderID
    }
    return availableActionActors.first?.agentId
  }

  func beginSessionLoad() -> UInt64 {
    sessionLoadSequence &+= 1
    activeSessionLoadRequest = sessionLoadSequence
    isSelectionLoading = true
    return sessionLoadSequence
  }

  func completeSessionLoad(_ requestID: UInt64) {
    guard activeSessionLoadRequest == requestID else {
      return
    }
    isSelectionLoading = false
  }

  func isCurrentSessionLoad(_ requestID: UInt64, sessionID: String) -> Bool {
    activeSessionLoadRequest == requestID && selectedSessionID == sessionID
  }

  func restorePersistedSessionSelection(sessionID: String) {
    if let cached = loadCachedSessionDetail(sessionID: sessionID) {
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: cached.detail,
        timeline: cached.timeline,
        showingCachedData: true
      )
    } else {
      isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
    }

    activeSessionLoadRequest = 0
    isSelectionLoading = false
  }

  func restorePersistedSessionState() {
    refreshPersistedSessionMetadata()

    if sessions.isEmpty, let cached = loadCachedSessionList() {
      sessionIndex.replaceSnapshot(
        projects: cached.projects,
        sessions: cached.sessions
      )
    }

    if case .offline = connectionState {
      isShowingCachedData = persistedSessionCount > 0 || !sessions.isEmpty
    }

    if let selectedSessionID, selectedSession?.session.sessionId != selectedSessionID {
      restorePersistedSessionSelection(sessionID: selectedSessionID)
    } else {
      activeSessionLoadRequest = 0
      isSelectionLoading = false
    }

    synchronizeActionActor()
  }

  func schedulePersistedSnapshotHydration(
    using client: any HarnessMonitorClientProtocol,
    sessions: [SessionSummary]
  ) {
    guard modelContext != nil, persistenceError == nil else {
      sessionSnapshotHydrationTask?.cancel()
      sessionSnapshotHydrationTask = nil
      return
    }

    let hydrationQueue = Array(sessions.filter(persistedSnapshotNeedsHydration))
    guard !hydrationQueue.isEmpty else {
      sessionSnapshotHydrationTask?.cancel()
      sessionSnapshotHydrationTask = nil
      return
    }

    sessionSnapshotHydrationTask?.cancel()
    sessionSnapshotHydrationTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer { self.sessionSnapshotHydrationTask = nil }

      for summary in hydrationQueue {
        guard !Task.isCancelled else {
          return
        }
        guard self.connectionState == .online else {
          return
        }

        do {
          async let detailResponse = Self.measureOperation {
            try await client.sessionDetail(id: summary.sessionId)
          }
          async let timelineResponse = Self.measureOperation {
            try await client.timeline(sessionID: summary.sessionId)
          }
          let measuredDetail = try await detailResponse
          let measuredTimeline = try await timelineResponse
          self.recordRequestSuccess()
          self.recordRequestSuccess()
          self.cacheSessionDetail(
            measuredDetail.value,
            timeline: measuredTimeline.value,
            markViewed: false
          )
        } catch {
          guard !Task.isCancelled else {
            return
          }
          self.appendConnectionEvent(
            kind: .error,
            detail: "Persisted snapshot refresh failed for \(summary.sessionId)"
          )
        }
      }
    }
  }
}

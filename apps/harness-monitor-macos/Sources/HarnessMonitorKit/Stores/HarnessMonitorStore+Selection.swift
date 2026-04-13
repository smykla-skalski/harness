import AppKit
import Foundation

extension HarnessMonitorStore {
  public var selectedSessionID: String? {
    get { selection.selectedSessionID }
    set {
      guard selection.selectedSessionID != newValue else { return }
      selection.selectedSessionID = newValue
    }
  }

  public var selectedSession: SessionDetail? {
    get { selection.selectedSession }
    set {
      guard selection.selectedSession != newValue else { return }
      selection.selectedSession = newValue
    }
  }

  public var timeline: [TimelineEntry] {
    get { selection.timeline }
    set {
      guard selection.timeline != newValue else { return }
      selection.timeline = newValue
    }
  }

  public var inspectorSelection: InspectorSelection {
    get { selection.inspectorSelection }
    set {
      guard selection.inspectorSelection != newValue else { return }
      selection.inspectorSelection = newValue
    }
  }

  public var actionActorID: String? {
    get { selection.actionActorID }
    set {
      guard selection.actionActorID != newValue else { return }
      selection.actionActorID = newValue
    }
  }

  public var selectedActionActorID: String {
    get { resolvedActionActor() ?? "" }
    set {
      let normalizedActorID = newValue.isEmpty ? nil : newValue
      guard actionActorID != normalizedActorID else { return }
      actionActorID = normalizedActorID
    }
  }

  public var isSelectionLoading: Bool {
    get { selection.isSelectionLoading }
    set {
      guard selection.isSelectionLoading != newValue else { return }
      selection.isSelectionLoading = newValue
    }
  }

  public var isExtensionsLoading: Bool {
    get { selection.isExtensionsLoading }
    set {
      guard selection.isExtensionsLoading != newValue else { return }
      selection.isExtensionsLoading = newValue
    }
  }

  public var isSessionActionInFlight: Bool {
    get { selection.isSessionActionInFlight }
    set {
      guard selection.isSessionActionInFlight != newValue else { return }
      selection.isSessionActionInFlight = newValue
    }
  }

  public var inFlightActionID: String? {
    get { selection.inFlightActionID }
    set {
      guard selection.inFlightActionID != newValue else { return }
      selection.inFlightActionID = newValue
    }
  }

  // MARK: - Navigation history

  public var canNavigateBack: Bool { !navigationBackStack.isEmpty }
  public var canNavigateForward: Bool { !navigationForwardStack.isEmpty }

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
    if !navigationForwardStack.isEmpty {
      navigationForwardStack.removeAll()
    }
  }

  private func loadSessionWithoutHistory(_ sessionID: String?) async {
    selectionTask?.cancel()
    primeSessionSelection(sessionID)

    guard let sessionID else {
      selectionTask = nil
      stopSessionStream()
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performSessionSelection(sessionID: sessionID)
      if !Task.isCancelled, self.selectedSessionID == sessionID {
        self.selectionTask = nil
      }
    }
    selectionTask = task
    await task.value
  }

  // MARK: - Selection

  public func primeSessionSelection(_ sessionID: String?) {
    let isChangingSelectedSession = selectedSession?.session.sessionId != sessionID

    if isChangingSelectedSession {
      cancelSessionLoad()
    }

    withUISyncBatch {
      recordNavigation(to: sessionID)
      cancelSessionPushFallback()
      if isChangingSelectedSession, inFlightActionID != nil {
        inFlightActionID = nil
      }
      selectedSessionID = sessionID
      inspectorSelection = .none
      isExtensionsLoading = false
      if pendingExtensions != nil {
        pendingExtensions = nil
      }
      resetSelectedCodexRuns()
      resetSelectedAgentTuis()
      if sessionID == nil {
        if activeSessionLoadRequest != 0 {
          activeSessionLoadRequest = 0
        }
        isSelectionLoading = false
        selectedSession = nil
        timeline = []
      } else if isChangingSelectedSession {
        isSelectionLoading = true
        selectedSession = nil
        timeline = []
      }
    }

    guard let sessionID else {
      stopSessionStream()
      return
    }

    guard selectedSession?.session.sessionId != sessionID else {
      return
    }
  }

  public func selectSession(_ sessionID: String?) async {
    selectSessionFromList(sessionID)

    guard let selectionTask else {
      return
    }

    await selectionTask.value
  }

  public func selectSessionFromList(_ sessionID: String?) {
    guard !shouldIgnoreDuplicateListSelection(for: sessionID) else {
      return
    }

    selectionTask?.cancel()
    primeSessionSelection(sessionID)

    guard let sessionID else {
      selectionTask = nil
      stopSessionStream()
      return
    }

    selectionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performSessionSelection(sessionID: sessionID)
      if !Task.isCancelled, self.selectedSessionID == sessionID {
        self.selectionTask = nil
      }
    }
  }

  private func shouldIgnoreDuplicateListSelection(for sessionID: String?) -> Bool {
    guard selectedSessionID == sessionID else {
      return false
    }
    guard let sessionID else {
      return true
    }
    if inspectorSelection != .none, selectedSession?.session.sessionId == sessionID {
      inspectorSelection = .none
      return true
    }
    if selectionTask != nil || isSelectionLoading {
      return true
    }
    return selectedSession?.session.sessionId == sessionID
  }

  private func performSessionSelection(sessionID: String) async {
    await applyCachedSessionIfAvailable(sessionID: sessionID)

    guard !Task.isCancelled else { return }

    guard connectionState == .online, let client else {
      await restorePersistedSessionSelection(sessionID: sessionID)
      stopSessionStream()
      return
    }

    guard !Task.isCancelled else { return }

    let requestID = beginSessionLoad()
    let loadTask = startSessionLoad(using: client, sessionID: sessionID, requestID: requestID)
    await loadTask.value
  }

  public func inspect(taskID: String) { inspectorSelection = .task(taskID) }
  public func inspect(agentID: String) { inspectorSelection = .agent(agentID) }
  public func inspect(signalID: String) { inspectorSelection = .signal(signalID) }
  public func inspectObserver() { inspectorSelection = .observer }

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

  func cancelSessionLoad() {
    sessionLoadTask?.cancel()
    sessionLoadTask = nil
  }

  func completeSessionLoad(_ requestID: UInt64) {
    guard activeSessionLoadRequest == requestID else {
      return
    }
    withUISyncBatch {
      isSelectionLoading = false
    }
  }

  func isCurrentSessionLoad(_ requestID: UInt64, sessionID: String) -> Bool {
    activeSessionLoadRequest == requestID && selectedSessionID == sessionID
  }

}

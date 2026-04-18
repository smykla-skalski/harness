import AppKit
import Foundation
import OpenTelemetryApi

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

  public var timelineWindow: TimelineWindowResponse? {
    get { selection.timelineWindow }
    set {
      guard selection.timelineWindow != newValue else { return }
      selection.timelineWindow = newValue
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

  public var isTimelineLoading: Bool {
    get { selection.isTimelineLoading }
    set {
      guard selection.isTimelineLoading != newValue else { return }
      selection.isTimelineLoading = newValue
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

  // MARK: - Selection

  public func primeSessionSelection(_ sessionID: String?) {
    let isChangingSelectedSession = selectedSession?.session.sessionId != sessionID

    if isChangingSelectedSession {
      cancelSelectedTimelinePageLoad()
      cancelSelectedSessionRefreshFallback()
      cancelSessionLoad()
    }

    synchronizeSessionBaggage(for: sessionID)

    withUISyncBatch {
      recordNavigation(to: sessionID)
      cancelSessionPushFallback()
      if isChangingSelectedSession, inFlightActionID != nil {
        inFlightActionID = nil
      }
      selection.retainPresentedDetailWhenSelectionClears = true
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
        isTimelineLoading = false
        selectedSession = nil
        timeline = []
        timelineWindow = nil
      } else if isChangingSelectedSession {
        isSelectionLoading = true
        isTimelineLoading = false
        selectedSession = nil
        timeline = []
        timelineWindow = nil
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
    cancelPendingListSelection()
    applyListSessionSelection(sessionID)

    guard let selectionTask else {
      return
    }

    await selectionTask.value
  }

  public func selectSessionFromList(_ sessionID: String?) {
    cancelPendingListSelection()

    pendingListSelectionTaskToken &+= 1
    let token = pendingListSelectionTaskToken
    let task = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled, self.pendingListSelectionTaskToken == token else {
        return
      }
      self.pendingListSelectionTask = nil
      self.applyListSessionSelection(sessionID)
    }
    pendingListSelectionTask = task
  }

  private func applyListSessionSelection(_ sessionID: String?) {
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

  private func cancelPendingListSelection() {
    pendingListSelectionTask?.cancel()
    pendingListSelectionTask = nil
    pendingListSelectionTaskToken &+= 1
  }

  func cancelSelectedTimelinePageLoad() {
    selectedTimelinePageLoadTask?.cancel()
    selectedTimelinePageLoadTask = nil
    selectedTimelinePageLoadKey = nil
    selectedTimelinePageLoadSequence &+= 1
  }

  func performSessionSelection(sessionID: String) async {
    let startedAt = ContinuousClock.now
    let span = HarnessMonitorTelemetry.shared.startSpan(
      name: "user.interaction.select_session",
      kind: .internal,
      attributes: ["session.id": .string(sessionID)]
    )
    defer {
      span.end()
      let elapsed = startedAt.duration(to: ContinuousClock.now)
      let durationMs = harnessMonitorDurationMilliseconds(elapsed)
      HarnessMonitorTelemetry.shared.recordUserInteraction(
        interaction: "select_session",
        sessionID: sessionID,
        durationMs: durationMs
      )
    }

    synchronizeSessionBaggage(for: sessionID)

    await HarnessMonitorTelemetryTaskContext.$parentSpanContext.withValue(span.context) {
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
  }

  public func loadSelectedTimelinePage(page: Int, pageSize: Int) async {
    guard pageSize > 0 else {
      return
    }
    guard let sessionID = selectedSessionID, let selectedSession, connectionState == .online,
      let client
    else {
      return
    }

    let totalCount = max(timeline.count, timelineWindow?.totalCount ?? 0)
    let pageCount = max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
    let clampedPage = min(max(page, 0), pageCount - 1)
    let targetEnd = min(totalCount, (clampedPage + 1) * pageSize)

    guard targetEnd > 0, timeline.count < targetEnd else {
      return
    }

    let currentRevision = timelineWindow?.revision
    let missingCount = targetEnd - timeline.count
    let loadKey = SelectedTimelinePageLoadKey(
      sessionID: sessionID,
      targetEnd: targetEnd,
      pageSize: pageSize,
      revision: currentRevision
    )

    if let selectedTimelinePageLoadTask, selectedTimelinePageLoadKey == loadKey {
      await selectedTimelinePageLoadTask.value
      return
    }

    cancelSelectedTimelinePageLoad()
    selectedTimelinePageLoadSequence &+= 1
    let token = selectedTimelinePageLoadSequence
    selectedTimelinePageLoadKey = loadKey

    withUISyncBatch {
      isTimelineLoading = true
    }
    let task = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        self.finishSelectedTimelinePageLoadIfCurrent(token, sessionID: sessionID)
      }

      do {
        let response = try await self.fetchSelectedTimelinePrefix(
          using: client,
          sessionID: sessionID,
          targetEnd: targetEnd,
          missingCount: missingCount,
          currentRevision: currentRevision
        )
        guard !Task.isCancelled else {
          return
        }
        guard self.isCurrentSelectedTimelinePageLoad(token, key: loadKey) else {
          return
        }
        self.applySelectedTimelinePageResponse(
          response,
          currentRevision: currentRevision,
          selectedSession: selectedSession
        )
      } catch is CancellationError {
        return
      } catch {
        guard self.isCurrentSelectedTimelinePageLoad(token, key: loadKey) else {
          return
        }
        let detail = error.localizedDescription
        HarnessMonitorLogger.store.warning(
          "timeline page load failed for \(sessionID, privacy: .public): \(detail, privacy: .public)"
        )
      }
    }
    selectedTimelinePageLoadTask = task
    await task.value
  }

  public func inspect(taskID: String) { inspectorSelection = .task(taskID) }
  public func inspect(agentID: String) { inspectorSelection = .agent(agentID) }
  public func inspect(signalID: String) { inspectorSelection = .signal(signalID) }
  public func inspectObserver() { inspectorSelection = .observer }

  func cancelSessionLoad() {
    sessionLoadTask?.cancel()
    sessionLoadTask = nil
    sessionSecondaryHydrationTask?.cancel()
    sessionSecondaryHydrationTask = nil
    cancelTimelineLoadingGate()
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

  func isCurrentSelectedTimelinePageLoad(
    _ token: UInt64,
    key: SelectedTimelinePageLoadKey
  ) -> Bool {
    selectedTimelinePageLoadSequence == token
      && selectedTimelinePageLoadKey == key
      && selectedSessionID == key.sessionID
  }

  func finishSelectedTimelinePageLoadIfCurrent(_ token: UInt64, sessionID: String) {
    guard selectedTimelinePageLoadSequence == token else {
      return
    }
    selectedTimelinePageLoadTask = nil
    selectedTimelinePageLoadKey = nil
    if selectedSessionID == sessionID {
      isTimelineLoading = false
    }
  }

}

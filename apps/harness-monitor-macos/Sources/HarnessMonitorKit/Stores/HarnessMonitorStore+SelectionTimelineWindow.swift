import Foundation

extension HarnessMonitorStore {
  public func loadSelectedTimelineWindow(
    request: TimelineWindowRequest,
    retainedLimit: Int? = nil
  ) async {
    guard let sessionID = selectedSessionID, let selectedSession, connectionState == .online,
      let client
    else {
      return
    }

    let loadKey = SelectedTimelineWindowLoadKey(sessionID: sessionID, request: request)
    if let selectedTimelineWindowLoadTask, selectedTimelineWindowLoadKey == loadKey {
      await selectedTimelineWindowLoadTask.value
      return
    }

    cancelSelectedTimelinePageLoad()
    cancelSelectedTimelineWindowLoad()
    selectedTimelineWindowLoadSequence &+= 1
    let token = selectedTimelineWindowLoadSequence
    selectedTimelineWindowLoadKey = loadKey

    withUISyncBatch {
      isTimelineLoading = true
    }
    let task = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        self.finishSelectedTimelineWindowLoadIfCurrent(token, sessionID: sessionID)
      }

      do {
        let response = try await Self.measureOperation {
          try await client.timelineWindow(sessionID: sessionID, request: request)
        }
        self.recordRequestSuccess()
        guard !Task.isCancelled else {
          return
        }
        guard self.isCurrentSelectedTimelineWindowLoad(token, key: loadKey) else {
          return
        }
        self.applySelectedTimelineWindowResponse(
          response.value,
          request: request,
          retainedLimit: retainedLimit,
          selectedSession: selectedSession
        )
      } catch is CancellationError {
        return
      } catch {
        guard self.isCurrentSelectedTimelineWindowLoad(token, key: loadKey) else {
          return
        }
        let detail = error.localizedDescription
        HarnessMonitorLogger.store.warning(
          """
          timeline window load failed for \
          \(sessionID, privacy: .public): \(detail, privacy: .public)
          """
        )
      }
    }
    selectedTimelineWindowLoadTask = task
    await task.value
  }

  func cancelSelectedTimelineWindowLoad() {
    selectedTimelineWindowLoadTask?.cancel()
    selectedTimelineWindowLoadTask = nil
    selectedTimelineWindowLoadKey = nil
    selectedTimelineWindowLoadSequence &+= 1
  }

  func applySelectedTimelineWindowResponse(
    _ response: TimelineWindowResponse,
    request: TimelineWindowRequest,
    retainedLimit: Int? = nil,
    selectedSession: SessionDetail
  ) {
    let resolved = resolvedSelectedTimelineWindow(
      response,
      request: request,
      retainedLimit: retainedLimit
    )
    let resolvedTimeline = resolved.timeline
    let resolvedTimelineWindow = resolved.timelineWindow

    withUISyncBatch {
      resetToolCallTimelineBurstState()
      timeline = resolvedTimeline
      timelineWindow = resolvedTimelineWindow
      isShowingCachedData = false
    }
    scheduleCacheWrite { service in
      await service.cacheSessionDetail(
        selectedSession,
        timeline: resolvedTimeline,
        timelineWindow: resolvedTimelineWindow
      )
    }
  }

  func isCurrentSelectedTimelineWindowLoad(
    _ token: UInt64,
    key: SelectedTimelineWindowLoadKey
  ) -> Bool {
    selectedTimelineWindowLoadSequence == token
      && selectedTimelineWindowLoadKey == key
      && selectedSessionID == key.sessionID
  }

  func finishSelectedTimelineWindowLoadIfCurrent(_ token: UInt64, sessionID: String) {
    guard selectedTimelineWindowLoadSequence == token else {
      return
    }
    selectedTimelineWindowLoadTask = nil
    selectedTimelineWindowLoadKey = nil
    if selectedSessionID == sessionID {
      isTimelineLoading = false
    }
  }
}

extension HarnessMonitorStore {
  struct SelectedTimelineWindowLoadKey: Equatable {
    let sessionID: String
    let request: TimelineWindowRequest
  }
}

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
    if let task = selectedTimelineLoad.windowLoadTask, selectedTimelineLoad.windowLoadKey == loadKey {
      await task.value
      return
    }

    cancelSelectedTimelinePageLoad()
    cancelSelectedTimelineWindowLoad()
    selectedTimelineLoad.windowLoadSequence &+= 1
    let token = selectedTimelineLoad.windowLoadSequence
    selectedTimelineLoad.windowLoadKey = loadKey

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
        await self.applySelectedTimelineWindowResponse(
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
    selectedTimelineLoad.windowLoadTask = task
    await task.value
  }

  func cancelSelectedTimelineWindowLoad() {
    selectedTimelineLoad.windowLoadTask?.cancel()
    selectedTimelineLoad.windowLoadTask = nil
    selectedTimelineLoad.windowLoadKey = nil
    selectedTimelineLoad.windowLoadSequence &+= 1
  }

  func applySelectedTimelineWindowResponse(
    _ response: TimelineWindowResponse,
    request: TimelineWindowRequest,
    retainedLimit: Int? = nil,
    selectedSession: SessionDetail
  ) async {
    let currentTimeline = timeline
    let currentWindow = timelineWindow
    let resolved = await timelineWindowWorker.resolveSelectedWindow(
      existingTimeline: currentTimeline,
      currentWindow: currentWindow,
      response: response,
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
    scheduleSelectedSessionCacheWrite(
      selectedSession,
      timeline: resolvedTimeline,
      timelineWindow: resolvedTimelineWindow
    )
  }

  func isCurrentSelectedTimelineWindowLoad(
    _ token: UInt64,
    key: SelectedTimelineWindowLoadKey
  ) -> Bool {
    selectedTimelineLoad.windowLoadSequence == token
      && selectedTimelineLoad.windowLoadKey == key
      && selectedSessionID == key.sessionID
  }

  func finishSelectedTimelineWindowLoadIfCurrent(_ token: UInt64, sessionID: String) {
    guard selectedTimelineLoad.windowLoadSequence == token else {
      return
    }
    selectedTimelineLoad.windowLoadTask = nil
    selectedTimelineLoad.windowLoadKey = nil
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

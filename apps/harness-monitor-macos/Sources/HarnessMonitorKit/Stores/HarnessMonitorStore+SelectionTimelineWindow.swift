import Foundation

extension HarnessMonitorStore {
  public func loadSelectedTimelineWindow(request: TimelineWindowRequest) async {
    guard let sessionID = selectedSessionID, let selectedSession, connectionState == .online,
      let client
    else {
      HarnessMonitorTimelineTrace.info(
        """
        store.window_skip reason=unavailable request=\(HarnessMonitorTimelineTrace.requestSummary(request)) \
        session=\(selectedSessionID ?? "nil") selected=\(self.selectedSession != nil) \
        state=\(String(describing: connectionState)) client=\(self.client != nil)
        """
      )
      return
    }

    let loadKey = SelectedTimelineWindowLoadKey(sessionID: sessionID, request: request)
    if let selectedTimelineWindowLoadTask, selectedTimelineWindowLoadKey == loadKey {
      HarnessMonitorTimelineTrace.info(
        """
        store.window_join_existing session=\(sessionID) \
        request=\(HarnessMonitorTimelineTrace.requestSummary(request))
        """
      )
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
    HarnessMonitorTimelineTrace.info(
      """
      store.window_task_start session=\(sessionID) \
      request=\(HarnessMonitorTimelineTrace.requestSummary(request))
      """
    )
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
        HarnessMonitorTimelineTrace.info(
          """
          store.window_response session=\(sessionID) \
          \(HarnessMonitorTimelineTrace.windowSummary(response.value))
          """
        )
        guard !Task.isCancelled else {
          HarnessMonitorTimelineTrace.info(
            "store.window_drop reason=cancelled session=\(sessionID)"
          )
          return
        }
        guard self.isCurrentSelectedTimelineWindowLoad(token, key: loadKey) else {
          HarnessMonitorTimelineTrace.info(
            "store.window_drop reason=stale session=\(sessionID)"
          )
          return
        }
        self.applySelectedTimelineWindowResponse(
          response.value,
          request: request,
          selectedSession: selectedSession
        )
      } catch is CancellationError {
        HarnessMonitorTimelineTrace.info("store.window_cancelled session=\(sessionID)")
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
    request _: TimelineWindowRequest,
    selectedSession: SessionDetail
  ) {
    let resolvedTimeline = response.entries ?? timeline
    let resolvedTimelineWindow =
      normalizedTimelineWindow(
        response.metadataOnly,
        loadedTimeline: resolvedTimeline
      ) ?? response.metadataOnly
    HarnessMonitorTimelineTrace.info(
      """
      store.apply_window response=\(HarnessMonitorTimelineTrace.windowSummary(response)) \
      oldLoaded=\(timeline.count) newLoaded=\(resolvedTimeline.count) \
      resolved=\(HarnessMonitorTimelineTrace.windowSummary(resolvedTimelineWindow))
      """
    )

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

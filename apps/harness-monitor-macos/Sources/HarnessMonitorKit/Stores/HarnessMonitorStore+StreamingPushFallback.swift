import Foundation

extension HarnessMonitorStore {
  func recoverSelectedSessionPushOnlyState(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async {
    await recoverSelectedCodexRunsAfterReconnect(
      using: client,
      sessionID: sessionID
    )
    await recoverSelectedAgentTuisAfterReconnect(
      using: client,
      sessionID: sessionID
    )
  }

  func scheduleSessionPushFallback(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) {
    // Repeated updates for the same selected session should coalesce into one
    // follow-up timeline refresh instead of continually restarting the timer.
    if pendingSessionPushFallback?.sessionID == sessionID {
      return
    }

    sessionPushFallbackSequence &+= 1
    let token = sessionPushFallbackSequence
    pendingSessionPushFallback = (sessionID: sessionID, token: token)
    sessionPushFallbackTask?.cancel()
    let delay = sessionPushFallbackDelayForSession(sessionID)
    sessionPushFallbackTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else {
        return
      }
      guard
        pendingSessionPushFallback?.token == token,
        pendingSessionPushFallback?.sessionID == sessionID,
        selectedSessionID == sessionID
      else {
        return
      }

      pendingSessionPushFallback = nil
      await self.performPushFallbackTimelineRefresh(using: client, sessionID: sessionID)
    }
  }

  func performPushFallbackTimelineRefresh(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async {
    lastSessionPushFallbackAt[sessionID] = ContinuousClock.now
    do {
      let timelineRequest = TimelineWindowRequest.latest(
        limit: selectedTimelineRequestLimit(
          loadedTimeline: timeline,
          timelineWindow: timelineWindow
        ),
        knownRevision: timelineWindow?.revision
      )
      let measuredTimeline = try await Self.measureOperation {
        try await client.timelineWindow(
          sessionID: sessionID,
          request: timelineRequest
        ) { [weak self] batch, batchIndex, _ in
          await MainActor.run {
            guard let entries = batch.entries else { return }
            self?.applySelectedTimelineBatch(
              entries,
              timelineWindow: batch.metadataOnly,
              index: batchIndex,
              sessionID: sessionID
            )
          }
        }
      }
      recordRequestSuccess()
      guard selectedSessionID == sessionID else {
        return
      }
      let resolvedTimeline = measuredTimeline.value.entries ?? timeline
      let resolvedTimelineWindow = measuredTimeline.value.metadataOnly
      timeline = resolvedTimeline
      self.timelineWindow = resolvedTimelineWindow
      if let selectedSession {
        scheduleCacheWrite { service in
          await service.cacheSessionDetail(
            selectedSession,
            timeline: resolvedTimeline,
            timelineWindow: resolvedTimelineWindow
          )
        }
      }
    } catch {
      // Background timer: log silently. The phantom "Daemon error" the
      // inspector used to show came from this catch block writing into
      // `lastError`, which the Action Console banner then rendered.
      HarnessMonitorLogger.store.warning(
        "push fallback timeline refresh failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func sessionPushFallbackDelayForSession(_ sessionID: String) -> Duration {
    let baseDelay = sessionPushFallbackDelay
    guard let lastRefreshAt = lastSessionPushFallbackAt[sessionID] else {
      return baseDelay
    }

    let now = ContinuousClock.now
    let throttleUntil = lastRefreshAt.advanced(by: sessionPushFallbackMinimumInterval)
    guard throttleUntil > now else {
      return baseDelay
    }

    let remaining = now.duration(to: throttleUntil)
    return remaining > baseDelay ? remaining : baseDelay
  }

  func cancelSessionPushFallback(for sessionID: String? = nil) {
    guard sessionID == nil || pendingSessionPushFallback?.sessionID == sessionID else {
      return
    }

    pendingSessionPushFallback = nil
    sessionPushFallbackTask?.cancel()
    sessionPushFallbackTask = nil
  }
}

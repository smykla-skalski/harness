import Foundation

extension HarnessMonitorStore {
  private static let sessionPushFallbackDelay = Duration.milliseconds(900)
  private static let streamReconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]
  private static let streamReconnectMaxAttempts = 6

  func reconnectDelay(for attempt: Int) -> Duration {
    Self.streamReconnectDelays[min(attempt, Self.streamReconnectDelays.count - 1)]
  }

  func startGlobalStream(using client: any HarnessMonitorClientProtocol) {
    stopGlobalStream()
    globalStreamTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          for try await event in await client.globalStream() {
            recordReconnectRecovery(detail: "Global stream restored")
            attempt = 0
            recordStreamEvent(countedInTraffic: true)
            if case .ready = event.kind {
              continue
            }
            applyGlobalPushEvent(event)
          }
        } catch {
          if Task.isCancelled {
            return
          }
          recordReconnectAttempt(scope: "global stream", nextAttempt: attempt + 1, error: error)
        }

        if Task.isCancelled {
          return
        }

        if attempt >= Self.streamReconnectMaxAttempts {
          appendConnectionEvent(
            kind: .reconnecting,
            detail: "Global stream failed \(attempt) times, re-bootstrapping"
          )
          await reconnect()
          return
        }

        let delay = reconnectDelay(for: attempt)
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
  }

  func startSessionStream(using client: any HarnessMonitorClientProtocol, sessionID: String) {
    subscribedSessionIDs = [sessionID]
    stopSessionStream(resetSubscriptions: false)
    sessionStreamTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      var attempt = 0
      while !Task.isCancelled {
        do {
          for try await event in await client.sessionStream(sessionID: sessionID) {
            recordReconnectRecovery(detail: "Session stream restored")
            attempt = 0
            let countedInTraffic = activeTransport == .httpSSE
            recordStreamEvent(countedInTraffic: countedInTraffic)
            if case .ready = event.kind {
              continue
            }
            applySessionPushEvent(event)
          }
        } catch {
          if Task.isCancelled {
            return
          }
          recordReconnectAttempt(scope: "session stream", nextAttempt: attempt + 1, error: error)
        }

        if Task.isCancelled {
          return
        }

        if attempt >= Self.streamReconnectMaxAttempts {
          appendConnectionEvent(
            kind: .reconnecting,
            detail: "Session stream failed \(attempt) times, re-bootstrapping"
          )
          await reconnect()
          return
        }

        let delay = reconnectDelay(for: attempt)
        attempt += 1
        try? await Task.sleep(for: delay)
      }
    }
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
    sessionPushFallbackTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      try? await Task.sleep(for: Self.sessionPushFallbackDelay)
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
      do {
        let measuredTimeline = try await Self.measureOperation {
          try await client.timeline(sessionID: sessionID)
        }
        recordRequestSuccess()
        guard selectedSessionID == sessionID else {
          return
        }
        timeline = measuredTimeline.value
        if let selectedSession {
          scheduleCacheWrite { service in
            let insertedCount = await service.cacheSessionDetail(
              selectedSession, timeline: measuredTimeline.value
            )
            self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
          }
        }
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  func cancelSessionPushFallback(for sessionID: String? = nil) {
    guard sessionID == nil || pendingSessionPushFallback?.sessionID == sessionID else {
      return
    }

    pendingSessionPushFallback = nil
    sessionPushFallbackTask?.cancel()
    sessionPushFallbackTask = nil
  }

  func applyGlobalPushEvent(_ event: DaemonPushEvent) {
    switch event.kind {
    case .ready:
      break
    case .sessionsUpdated(let payload):
      applySessionIndexSnapshot(
        projects: payload.projects,
        sessions: payload.sessions
      )
      refreshSelectedSessionIfSummaryChanged(sessions: payload.sessions)
    case .sessionUpdated(let payload):
      guard let sessionID = event.sessionId else {
        return
      }
      handleGlobalSessionUpdate(sessionID: sessionID, payload: payload)
    case .sessionExtensions(let payload):
      applySessionExtensions(payload)
    case .logLevelChanged(let response):
      daemonLogLevel = response.level
    case .codexRunUpdated(let run):
      applyCodexRun(run)
    case .codexApprovalRequested(let payload):
      applyCodexApprovalRequested(payload)
    case .unknown:
      break
    }
  }

  private func handleGlobalSessionUpdate(
    sessionID: String,
    payload: SessionUpdatedPayload
  ) {
    let detail = sessionDetailPreservingSelectedExtensions(
      sessionID: sessionID,
      detail: payload.detail,
      extensionsPending: payload.extensionsPending == true
    )
    if payload.extensionsPending != true {
      isExtensionsLoading = false
    }
    guard sessionID == selectedSessionID else {
      applySessionSummaryUpdate(detail.session)
      if let timeline = payload.timeline {
        scheduleCacheWrite { service in
          let insertedCount = await service.cacheSessionDetail(
            detail, timeline: timeline, markViewed: false
          )
          self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
        }
      }
      return
    }
    let timeline = payload.timeline ?? self.timeline
    applySelectedSessionSnapshot(
      sessionID: sessionID,
      detail: detail,
      timeline: timeline,
      showingCachedData: false,
      cancelPendingTimelineRefresh: payload.timeline != nil
    )
    if let freshTimeline = payload.timeline {
      scheduleCacheWrite { service in
        let insertedCount = await service.cacheSessionDetail(detail, timeline: freshTimeline)
        self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
      }
    } else if let client {
      scheduleSessionPushFallback(using: client, sessionID: sessionID)
    }
  }

  func refreshSelectedSessionIfSummaryChanged(sessions: [SessionSummary]) {
    guard let client,
      let selectedSessionID,
      let updatedSummary = sessions.first(where: { $0.sessionId == selectedSessionID }),
      selectedSession?.session != updatedSummary
    else {
      return
    }

    let requestID = beginSessionLoad()
    Task { @MainActor [weak self] in
      await self?.loadSession(
        using: client,
        sessionID: selectedSessionID,
        requestID: requestID
      )
    }
  }

  func applySessionPushEvent(_ event: DaemonPushEvent) {
    switch event.kind {
    case .ready, .sessionsUpdated, .logLevelChanged, .unknown:
      break
    case .codexRunUpdated(let run):
      applyCodexRun(run)
    case .codexApprovalRequested(let payload):
      applyCodexApprovalRequested(payload)
    case .sessionUpdated(let payload):
      guard let sessionID = event.sessionId else {
        return
      }
      let detail = sessionDetailPreservingSelectedExtensions(
        sessionID: sessionID,
        detail: payload.detail,
        extensionsPending: payload.extensionsPending == true
      )
      if payload.extensionsPending != true {
        isExtensionsLoading = false
      }
      let timeline = payload.timeline ?? self.timeline
      applySelectedSessionSnapshot(
        sessionID: sessionID,
        detail: detail,
        timeline: timeline,
        showingCachedData: false,
        cancelPendingTimelineRefresh: payload.timeline != nil
      )
      if let freshTimeline = payload.timeline {
        scheduleCacheWrite { service in
          let insertedCount = await service.cacheSessionDetail(detail, timeline: freshTimeline)
          self.updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedCount)
        }
      } else if let client {
        scheduleSessionPushFallback(using: client, sessionID: sessionID)
      }
    case .sessionExtensions(let payload):
      applySessionExtensions(payload)
    }
  }

  func startManifestWatcher() {
    stopManifestWatcher()
    let daemonRoot = HarnessMonitorPaths.daemonRoot()
    // The dispatch source opens the daemon directory; create it first so the
    // watcher still starts when the dev daemon has never run yet. This is
    // required for external daemon mode where the app may launch before the
    // terminal daemon exists.
    try? FileManager.default.createDirectory(
      at: daemonRoot,
      withIntermediateDirectories: true
    )
    let manifestURL = HarnessMonitorPaths.manifestURL()
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let currentEndpoint: String
    if let data = FileManager.default.contents(atPath: manifestURL.path),
      let manifest = try? decoder.decode(DaemonManifest.self, from: data)
    {
      currentEndpoint = manifest.endpoint
    } else {
      // Manifest missing or undecodable; start with an empty sentinel so the
      // first valid manifest write triggers reconnect.
      currentEndpoint = ""
    }
    let watcher = ManifestWatcher(currentEndpoint: currentEndpoint) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.appendConnectionEvent(
          kind: .reconnecting,
          detail: "Daemon manifest changed, re-bootstrapping"
        )
        await self.reconnect()
      }
    }
    manifestWatcher = watcher
    watcher.start()
  }

  func stopManifestWatcher() {
    manifestWatcher?.stop()
    manifestWatcher = nil
  }
}

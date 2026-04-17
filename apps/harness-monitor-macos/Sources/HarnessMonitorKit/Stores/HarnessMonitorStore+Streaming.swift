import Foundation

extension HarnessMonitorStore {
  static let streamReconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]
  private static let streamReconnectMaxAttempts = 6

  func startGlobalStream(using client: any HarnessMonitorClientProtocol) {
    stopGlobalStream()
    guard maintainsLiveDaemonObservation else {
      return
    }
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
              await recoverGlobalPushOnlyState(using: client)
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
    guard maintainsLiveDaemonObservation else {
      stopSessionStream()
      return
    }
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
              await recoverSelectedSessionPushOnlyState(
                using: client,
                sessionID: sessionID
              )
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

  private func recoverGlobalPushOnlyState(
    using client: any HarnessMonitorClientProtocol
  ) async {
    do {
      let measuredLogLevel = try await Self.measureOperation {
        try await client.logLevel()
      }
      recordRequestSuccess()
      daemonLogLevel = measuredLogLevel.value.level
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect log-level refresh failed: \(err, privacy: .public)"
      )
    }
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
    case .agentTuiUpdated(let tui):
      applyAgentTui(tui)
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
          await service.cacheSessionDetail(
            detail,
            timeline: timeline,
            timelineWindow: TimelineWindowResponse.fallbackMetadata(for: timeline),
            markViewed: false
          )
        }
      }
      return
    }
    let timeline = payload.timeline ?? self.timeline
    applySelectedSessionSnapshot(
      sessionID: sessionID,
      detail: detail,
      timeline: timeline,
      timelineWindow: payload.timeline.map(TimelineWindowResponse.fallbackMetadata(for:))
        ?? timelineWindow,
      showingCachedData: false,
      cancelPendingTimelineRefresh: payload.timeline != nil
    )
    if let freshTimeline = payload.timeline {
      scheduleCacheWrite { service in
        await service.cacheSessionDetail(
          detail,
          timeline: freshTimeline,
          timelineWindow: TimelineWindowResponse.fallbackMetadata(for: freshTimeline)
        )
      }
    } else if let client {
      scheduleSessionPushFallback(using: client, sessionID: sessionID)
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
    case .agentTuiUpdated(let tui):
      applyAgentTui(tui)
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
        timelineWindow: payload.timeline.map(TimelineWindowResponse.fallbackMetadata(for:))
          ?? timelineWindow,
        showingCachedData: false,
        cancelPendingTimelineRefresh: payload.timeline != nil
      )
      if let freshTimeline = payload.timeline {
        scheduleCacheWrite { service in
          await service.cacheSessionDetail(
            detail,
            timeline: freshTimeline,
            timelineWindow: TimelineWindowResponse.fallbackMetadata(for: freshTimeline)
          )
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
    guard maintainsLiveDaemonObservation else {
      return
    }
    let daemonRoot = manifestURL.deletingLastPathComponent()
    // The dispatch source opens the daemon directory; create it first so the
    // watcher still starts when the dev daemon has never run yet. This is
    // required for external daemon mode where the app may launch before the
    // terminal daemon exists.
    try? FileManager.default.createDirectory(
      at: daemonRoot,
      withIntermediateDirectories: true
    )
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let currentEndpoint: String
    let currentStartedAt: String?
    let currentRevision: UInt64
    if let data = FileManager.default.contents(atPath: manifestURL.path),
      let manifest = try? decoder.decode(DaemonManifest.self, from: data)
    {
      currentEndpoint = manifest.endpoint
      currentStartedAt = manifest.startedAt
      currentRevision = manifest.revision
    } else {
      // Manifest missing or undecodable; start with an empty sentinel so the
      // first valid manifest write triggers reconnect.
      currentEndpoint = ""
      currentStartedAt = nil
      currentRevision = 0
    }
    let watcher = ManifestWatcher(
      manifestURL: manifestURL,
      currentEndpoint: currentEndpoint,
      currentStartedAt: currentStartedAt,
      currentRevision: currentRevision
    ) { [weak self] change in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch change {
        case .connectionChange:
          self.appendConnectionEvent(
            kind: .reconnecting,
            detail: "Daemon manifest changed, re-bootstrapping"
          )
          await self.reconnect()
        case .inPlaceUpdate(let manifest):
          self.applyManifestRevision(manifest)
        }
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

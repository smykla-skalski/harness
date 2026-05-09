import Foundation

extension HarnessMonitorStore {
  public func sessionWindowSnapshot(
    sessionID: String
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    guard !Task.isCancelled else { return nil }
    if connectionState == .online, let client {
      if let liveSnapshot = await loadLiveSessionWindowSnapshot(
        sessionID: sessionID,
        client: client
      ) {
        return liveSnapshot
      }
      guard !Task.isCancelled else { return nil }
    }

    if let cached = await loadCachedSessionDetail(sessionID: sessionID) {
      guard !Task.isCancelled else { return nil }
      return HarnessMonitorSessionWindowSnapshot(
        summary: cached.detail.session,
        detail: cached.detail,
        timeline: cached.timeline,
        timelineWindow: cached.timelineWindow,
        source: .cache
      )
    }

    guard !Task.isCancelled else { return nil }
    guard let summary = sessionIndex.sessionSummary(for: sessionID) else {
      return nil
    }
    return HarnessMonitorSessionWindowSnapshot(
      summary: summary,
      detail: nil,
      timeline: [],
      timelineWindow: nil,
      source: .catalog
    )
  }

  private func loadLiveSessionWindowSnapshot(
    sessionID: String,
    client: any HarnessMonitorClientProtocol
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    do {
      let detailScope = activeTransport == .webSocket ? "core" : nil
      let detail = try await client.sessionDetail(id: sessionID, scope: detailScope)
      guard !Task.isCancelled else { return nil }
      let timelineWindow = try? await client.timelineWindow(
        sessionID: sessionID,
        request: .latest(limit: Self.initialSelectedTimelineWindowLimit)
      ) { _, _, _ in }
      guard !Task.isCancelled else { return nil }
      return HarnessMonitorSessionWindowSnapshot(
        summary: detail.session,
        detail: detail,
        timeline: timelineWindow?.entries ?? [],
        timelineWindow: timelineWindow,
        source: .live
      )
    } catch {
      guard !(error is CancellationError) else {
        return nil
      }
      let errorDescription = String(describing: error)
      HarnessMonitorLogger.store.debug(
        """
        session window live load failed \
        sessionID=\(sessionID, privacy: .public) \
        error=\(errorDescription, privacy: .public)
        """
      )
      return nil
    }
  }
}

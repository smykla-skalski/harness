import HarnessMonitorKit

extension SessionWindowView {
  var sessionTimelineLoading: SessionTimelineLoading {
    SessionTimelineLoading(
      loadOlderChunk: { presentation, limit in
        guard let request = presentation.navigation.request(for: .older, limit: limit) else {
          return
        }
        await loadSessionWindowTimeline(request)
      },
      loadWindow: { request in
        await loadSessionWindowTimeline(request)
      }
    )
  }

  @MainActor
  func loadSessionWindowTimeline(_ request: TimelineWindowRequest) async {
    guard let currentSnapshot = snapshot else {
      return
    }
    isLoading = true
    defer { isLoading = false }
    guard
      let nextSnapshot = await store.loadSessionWindowTimeline(
        sessionID: token.sessionID,
        snapshot: currentSnapshot,
        request: request
      )
    else {
      return
    }
    snapshot = nextSnapshot
    didLoadSnapshot = true
  }
}

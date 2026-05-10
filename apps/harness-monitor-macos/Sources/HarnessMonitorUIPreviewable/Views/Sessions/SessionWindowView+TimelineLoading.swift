import HarnessMonitorKit

extension SessionWindowView {
  var sessionTimelineLoading: SessionTimelineLoading {
    SessionTimelineLoading(
      loadOlderChunk: { presentation, limit, retainedLimit in
        guard let request = presentation.navigation.request(for: .older, limit: limit) else {
          return
        }
        await loadSessionWindowTimeline(request, retainedLimit: retainedLimit)
      },
      loadWindow: { request, retainedLimit in
        await loadSessionWindowTimeline(request, retainedLimit: retainedLimit)
      }
    )
  }

  @MainActor
  func loadSessionWindowTimeline(
    _ request: TimelineWindowRequest,
    retainedLimit: Int? = nil
  ) async {
    guard let currentSnapshot = snapshot else {
      return
    }
    isLoading = true
    defer { isLoading = false }
    guard
      let nextSnapshot = await store.loadSessionWindowTimeline(
        sessionID: token.sessionID,
        snapshot: currentSnapshot,
        request: request,
        retainedLimit: retainedLimit
      )
    else {
      return
    }
    snapshot = nextSnapshot
    didLoadSnapshot = true
  }
}

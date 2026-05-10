extension SessionTimelineTableView.Coordinator {
  func beginLiveScroll() {
    isViewportMoving = true
    liveScrollEndTask?.cancel()
    liveScrollEndTask = nil
  }

  func endLiveScroll() {
    liveScrollEndTask?.cancel()
    liveScrollEndTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 60_000_000)
      guard let self, !Task.isCancelled else { return }
      self.isViewportMoving = false
      self.liveScrollEndTask = nil
      self.boundsDidChange(forceObservedStats: true, suppressBoundaryCallbacks: true)
    }
  }

  func cancelLiveScrollTracking() {
    liveScrollEndTask?.cancel()
    liveScrollEndTask = nil
    isViewportMoving = false
  }
}

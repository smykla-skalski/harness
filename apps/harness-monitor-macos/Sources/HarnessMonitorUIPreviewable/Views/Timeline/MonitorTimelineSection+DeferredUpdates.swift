extension SessionTimelineView {
  /// Run a state-mutating closure on the next run-loop turn instead of inside
  /// SwiftUI's current view-update phase. Required for writes that touch state
  /// read by this view body or its observable children.
  ///
  /// Call only from change-event handlers, never from per-scroll publishes.
  func deferOffViewUpdate(_ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
      work()
    }
  }
}

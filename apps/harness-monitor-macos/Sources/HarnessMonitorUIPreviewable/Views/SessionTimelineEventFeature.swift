import HarnessMonitorKit

// Live region priority for signal-adjacent features is handled in
// MonitorTimelineLiveRegion.priority(for:summary:). Add cases there when adding a new feature family.
protocol TimelineEventFeature: Sendable {
  static var id: String { get }
  func handles(entry: TimelineEntry) -> Bool
  func tapTarget(for entry: TimelineEntry) -> TimelineTapTarget?
  func tone(for entry: TimelineEntry) -> SessionTimelineTone?
  func actions(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> [SessionTimelineAction]
  func contextMenuItems(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> [TimelineContextMenuItem]
  func prefersCompactLayout(for node: SessionTimelineNode) -> Bool?
  func voiceOverLabel(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> String?
  func statusBadgeLabel(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> String?
}

extension TimelineEventFeature {
  func tapTarget(for entry: TimelineEntry) -> TimelineTapTarget? { nil }
  func tone(for entry: TimelineEntry) -> SessionTimelineTone? { nil }
  func actions(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> [SessionTimelineAction] { [] }
  func contextMenuItems(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> [TimelineContextMenuItem] { [] }
  func prefersCompactLayout(for node: SessionTimelineNode) -> Bool? { nil }
  func voiceOverLabel(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> String? { nil }
  func statusBadgeLabel(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> String? { nil }
}

enum SessionTimelineEventFeatureRegistry {
  // Ordered: first match wins. Add new features before the catch-all decision feature.
  static let features: [any TimelineEventFeature] = [
    SignalTimelineEventFeature(),
    DecisionEventFeature(),
  ]

  static func firstMatch(for entry: TimelineEntry) -> (any TimelineEventFeature)? {
    features.first { $0.handles(entry: entry) }
  }
}

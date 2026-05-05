import HarnessMonitorKit

protocol TimelineEventFeature: Sendable {
  static var id: String { get }
  func handles(entry: TimelineEntry) -> Bool
  func patch(for entry: TimelineEntry) -> TimelineEntryMetadataPatch
  func tone(for entry: TimelineEntry) -> SessionTimelineTone?
  func liveRegionPriority(for entry: TimelineEntry) -> MonitorTimelineLiveRegionPriority?
  func actions(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> [SessionTimelineAction]
  func contextMenuItems(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> [TimelineContextMenuItem]
  func prefersCompactLayout(for node: SessionTimelineNode) -> Bool?
  func voiceOverLabel(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> String?
  func filterPreset() -> TimelineFilterPreset?
  func statusBadge(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> SessionTimelineStatusBadge?
}

extension TimelineEventFeature {
  func patch(for entry: TimelineEntry) -> TimelineEntryMetadataPatch { .empty }
  func tone(for entry: TimelineEntry) -> SessionTimelineTone? { nil }
  func liveRegionPriority(for entry: TimelineEntry) -> MonitorTimelineLiveRegionPriority? { nil }
  func actions(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> [SessionTimelineAction] { [] }
  func contextMenuItems(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> [TimelineContextMenuItem] { [] }
  func prefersCompactLayout(for node: SessionTimelineNode) -> Bool? { nil }
  func voiceOverLabel(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> String? { nil }
  func filterPreset() -> TimelineFilterPreset? { nil }
  func statusBadge(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> SessionTimelineStatusBadge? { nil }
}

struct TimelineFilterPreset: Equatable, Sendable {
  let id: String
  let kinds: Set<String>
}

enum SessionTimelineEventFeatureRegistry {
  // Ordered: first match wins. Add new features before the catch-all decision feature.
  static let features: [any TimelineEventFeature] = [
    DecisionEventFeature(),
  ]

  static func firstMatch(for entry: TimelineEntry) -> (any TimelineEventFeature)? {
    features.first { $0.handles(entry: entry) }
  }
}

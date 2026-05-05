import HarnessMonitorKit

struct DecisionEventFeature: TimelineEventFeature {
  static let id = "decision"

  func handles(entry: TimelineEntry) -> Bool {
    SessionTimelineNodeBuilder.explicitDecisionID(in: entry.payload) != nil
  }

  func actions(for node: SessionTimelineNode, ctx: TimelineFeatureContext) -> [SessionTimelineAction] {
    node.decision?.actions ?? []
  }
}

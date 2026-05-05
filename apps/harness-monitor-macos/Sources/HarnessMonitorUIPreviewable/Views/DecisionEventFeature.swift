import HarnessMonitorKit

struct DecisionEventFeature: TimelineEventFeature {
  static let id = "decision"

  func handles(entry: TimelineEntry) -> Bool {
    SessionTimelineNodeBuilder.explicitDecisionID(in: entry.payload) != nil
  }

  func actions(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> [SessionTimelineAction] {
    // Re-expose decision actions so the feature dispatch pipeline does not zero them out.
    // The builder populates node.decision before calling feature dispatch (entryNode(for:)).
    node.decision?.actions ?? []
  }
}

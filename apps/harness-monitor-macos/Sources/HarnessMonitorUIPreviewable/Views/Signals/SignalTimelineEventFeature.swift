import HarnessMonitorKit

struct SignalTimelineEventFeature: TimelineEventFeature {
  static let id = "signal"

  func handles(entry: TimelineEntry) -> Bool {
    entry.kind.hasPrefix("signal_")
  }

  func tapTarget(for entry: TimelineEntry) -> TimelineTapTarget? {
    guard let signalID = SessionTimelineNodeBuilder.extractSignalID(from: entry.payload) else {
      return nil
    }
    return .signal(id: signalID)
  }

  func tone(for entry: TimelineEntry) -> SessionTimelineTone? {
    switch entry.kind {
    case "signal_sent", "signal_received":
      return .info
    case "signal_acknowledged":
      let value = entry.summary.lowercased()
      if value.contains("rejected") || value.contains("fail") || value.contains("denied") {
        return .critical
      }
      if value.contains("expired") || value.contains("deferred") { return .warning }
      if value.contains("accepted") || value.contains("delivered") { return .success }
      return .info
    default:
      return .info
    }
  }

  func prefersCompactLayout(for _: SessionTimelineNode) -> Bool? { true }

  func actions(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> [SessionTimelineAction] {
    guard case .signal(let signalID) = node.tapTarget,
      let record = ctx.signalsByID[signalID]
    else { return [] }
    switch record.effectiveStatus(now: ctx.now) {
    case .pending:
      return [.cancelSignal(signalID: signalID, agentID: record.agentId)]
    case .expired:
      return [.resendSignal(record)]
    default:
      return []
    }
  }

  func contextMenuItems(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> [TimelineContextMenuItem] {
    guard case .signal(let signalID) = node.tapTarget else { return [] }
    return [
      TimelineContextMenuItem(
        label: "Inspect",
        systemImage: "info.circle",
        action: .openSignal(id: signalID)
      ),
      TimelineContextMenuItem(
        label: "Copy Signal ID",
        systemImage: "doc.on.doc",
        action: .copyText(signalID)
      ),
    ]
  }

  func voiceOverLabel(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> String? {
    guard case .signal(let signalID) = node.tapTarget else { return nil }
    let status =
      ctx.signalsByID[signalID]?.effectiveStatus(now: ctx.now).title
      ?? statusVerb(for: node)
    return ["Signal \(status)", node.title, node.actionAvailabilityLabel]
      .joined(separator: ", ")
  }

  func statusBadgeLabel(
    for node: SessionTimelineNode,
    ctx: TimelineFeatureContext
  ) -> String? {
    if case .signal(let signalID) = node.tapTarget,
      let record = ctx.signalsByID[signalID]
    {
      return record.effectiveStatus(now: ctx.now).title
    }
    return statusVerb(for: node)
  }

  // Dispatches on entry.kind (node.sourceLabel) as primary discriminator.
  // For signal_acknowledged the daemon encodes the outcome (Accepted/Rejected/Deferred/Expired)
  // only in the human-readable summary; the payload carries signal_id but not a structured
  // result field. The title scan is therefore the only available discriminator for that case.
  private func statusVerb(for node: SessionTimelineNode) -> String {
    switch node.sourceLabel {
    case "signal_sent": return "Sent"
    case "signal_received": return "Received"
    default:
      let lower = node.title.lowercased()
      if lower.contains("accepted") || lower.contains("delivered") { return "Delivered" }
      if lower.contains("rejected") { return "Rejected" }
      if lower.contains("deferred") { return "Deferred" }
      if lower.contains("expired") { return "Expired" }
      return "Acknowledged"
    }
  }
}

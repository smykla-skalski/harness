import HarnessMonitorKit

// LIVE REGION: when adding a new signal kind, also add a case to
// MonitorTimelineLiveRegion.priority(for:summary:). See SessionTimelineEventFeature.swift
// for design rationale; note that live-region urgency vocabulary intentionally differs from
// the tone/verb vocabulary in acknowledgedOutcome below.
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
      return acknowledgedOutcome(from: entry.summary).tone
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

  // Dispatches on node.sourceLabel (entry.kind). For signal_acknowledged the daemon
  // encodes the outcome only in the summary; acknowledgedOutcome(_:) is the single parse
  // site. The default branch is a true fallback for unknown future signal kinds — add an
  // explicit case here when introducing a new kind rather than relying on that fallback.
  private func statusVerb(for node: SessionTimelineNode) -> String {
    switch node.sourceLabel {
    case "signal_sent": return "Sent"
    case "signal_received": return "Received"
    case "signal_acknowledged": return acknowledgedOutcome(from: node.title).verb
    default: return "Acknowledged"
    }
  }

  // Single parse site for signal_acknowledged outcome vocabulary. Both tone(for:) and
  // statusVerb(for:) delegate here so the keyword list stays in sync. Both callers pass
  // the entry summary string: tone passes entry.summary directly; statusVerb passes
  // node.title, which the builder sets to entry.summary (see entryNode(for:) in
  // SessionTimelineNodeBuilder — title is a let field, never mutated after construction).
  //
  // Vocabulary is intentionally wider than MonitorTimelineLiveRegion's assertive gate
  // (rejected/expired/deferred only): fail and denied also map to .critical here because
  // display tone is finer-grained than live-region urgency. When adding a new outcome
  // keyword here, evaluate whether it also warrants assertive live-region priority.
  private func acknowledgedOutcome(from summary: String) -> (tone: SessionTimelineTone, verb: String) {
    let lower = summary.lowercased()
    if lower.contains("rejected") || lower.contains("fail") || lower.contains("denied") {
      return (.critical, "Rejected")
    }
    if lower.contains("deferred") { return (.warning, "Deferred") }
    if lower.contains("expired") { return (.warning, "Expired") }
    if lower.contains("accepted") || lower.contains("delivered") { return (.success, "Delivered") }
    return (.info, "Acknowledged")
  }
}

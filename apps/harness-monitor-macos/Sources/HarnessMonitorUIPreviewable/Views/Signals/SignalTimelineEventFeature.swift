import HarnessMonitorKit

// LIVE REGION: when adding a new signal kind, also add a case to
// MonitorTimelineLiveRegion.priority(for:summary:) — that function runs before node
// enrichment and is outside this protocol.
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

  // Dispatches on node.sourceLabel (entry.kind) as primary discriminator.
  // For signal_acknowledged the daemon encodes the outcome only in the human-readable
  // summary; acknowledgedOutcome(_:) is the single parse site for that case.
  private func statusVerb(for node: SessionTimelineNode) -> String {
    switch node.sourceLabel {
    case "signal_sent": return "Sent"
    case "signal_received": return "Received"
    default: return acknowledgedOutcome(from: node.title).verb
    }
  }

  // Single parse site for signal_acknowledged outcome vocabulary.
  // Both tone(for:) and statusVerb(for:) delegate here so the keyword list stays in sync.
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

import HarnessMonitorKit

struct SignalTimelineEventFeature: TimelineEventFeature {
  static let id = "signal"

  func handles(entry: TimelineEntry) -> Bool {
    entry.kind.hasPrefix("signal_")
  }

  func patch(for entry: TimelineEntry) -> TimelineEntryMetadataPatch {
    guard let signalID = SessionTimelineNodeBuilder.extractSignalID(from: entry.payload) else {
      return .empty
    }
    return TimelineEntryMetadataPatch(tapTarget: .signal(id: signalID))
  }

  func tone(for entry: TimelineEntry) -> SessionTimelineTone? {
    let value = entry.summary.lowercased()
    if value.contains("critical") || value.contains("error") || value.contains("fail")
      || value.contains("denied") || value.contains("rejected")
    {
      return .critical
    }
    if value.contains("warn") || value.contains("blocked") || value.contains("stale")
      || value.contains("retry") || value.contains("expired") || value.contains("deferred")
    {
      return .warning
    }
    if value.contains("success") || value.contains("complete") || value.contains("accepted")
      || value.contains("approved") || value.contains("delivered")
    {
      return .success
    }
    return .info
  }

  func liveRegionPriority(for entry: TimelineEntry) -> MonitorTimelineLiveRegionPriority? {
    switch entry.kind {
    case "signal_sent", "signal_received":
      return .polite
    case "signal_acknowledged":
      let lower = entry.summary.lowercased()
      return lower.contains("rejected") || lower.contains("expired") || lower.contains("deferred")
        ? .assertive : .polite
    default:
      return nil
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
      ?? statusVerb(from: node.title)
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
    return statusVerb(from: node.title)
  }

  private func statusVerb(from title: String) -> String {
    let lower = title.lowercased()
    if lower.contains("accepted") || lower.contains("delivered") { return "Delivered" }
    if lower.contains("rejected") { return "Rejected" }
    if lower.contains("deferred") { return "Deferred" }
    if lower.contains("expired") { return "Expired" }
    if lower.contains("picked up") || lower.contains("received") { return "Received" }
    return "Sent"
  }
}

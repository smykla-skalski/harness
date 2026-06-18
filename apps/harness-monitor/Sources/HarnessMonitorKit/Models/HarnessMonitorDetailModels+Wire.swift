import Foundation

// Wire maps for the SessionDetail.observer member (ObserverSummary). The rich models String-type
// the observe enums and rename ObserverOpenIssue -> ObserverIssueSummary, so the map reads each
// open enum's .rawValue, narrows the UInt counts/lines to Int, and wraps the wire's non-optional
// member arrays into the rich model's optional fields (the daemon always emits them).

extension ObserverIssueSummary {
  init(wire: ObserverOpenIssueWire) {
    self.init(
      issueId: wire.issueId,
      code: wire.code.rawValue,
      summary: wire.summary,
      severity: wire.severity.rawValue,
      category: wire.category.rawValue,
      fingerprint: wire.fingerprint,
      firstSeenLine: Int(wire.firstSeenLine),
      lastSeenLine: Int(wire.lastSeenLine),
      occurrenceCount: Int(wire.occurrenceCount),
      fixSafety: wire.fixSafety.rawValue,
      evidenceExcerpt: wire.evidenceExcerpt
    )
  }
}

extension ObserverWorkerSummary {
  init(wire: ObserverActiveWorkerWire) {
    self.init(
      issueId: wire.issueId,
      targetFile: wire.targetFile,
      startedAt: wire.startedAt,
      agentId: wire.agentId,
      runtime: wire.runtime
    )
  }
}

extension ObserverAgentSessionSummary {
  init(wire: ObserverAgentSessionSummaryWire) {
    self.init(
      agentId: wire.agentId,
      runtime: wire.runtime,
      logPath: wire.logPath,
      cursor: Int(wire.cursor),
      lastActivity: wire.lastActivity
    )
  }
}

extension ObserverSummary {
  init(wire: ObserverSummaryWire) {
    self.init(
      observeId: wire.observeId,
      lastScanTime: wire.lastScanTime,
      openIssueCount: Int(wire.openIssueCount),
      resolvedIssueCount: Int(wire.resolvedIssueCount),
      mutedCodeCount: Int(wire.mutedCodeCount),
      activeWorkerCount: Int(wire.activeWorkerCount),
      openIssues: wire.openIssues.map(ObserverIssueSummary.init(wire:)),
      mutedCodes: wire.mutedCodes.map(\.rawValue),
      activeWorkers: wire.activeWorkers.map(ObserverWorkerSummary.init(wire:)),
      agentSessions: wire.agentSessions.map(ObserverAgentSessionSummary.init(wire:))
    )
  }
}

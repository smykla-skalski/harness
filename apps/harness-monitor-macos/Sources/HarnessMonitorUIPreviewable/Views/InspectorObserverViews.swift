import HarnessMonitorKit
import SwiftUI

struct ObserverInspectorCard: View {
  let observer: ObserverSummary

  private var facts: [InspectorFact] {
    [
      .init(title: "Observer", value: observer.observeId),
      .init(title: "Open Issues", value: "\(observer.openIssueCount)"),
      .init(title: "Resolved", value: "\(observer.resolvedIssueCount)"),
      .init(title: "Active Workers", value: "\(observer.activeWorkerCount)"),
      .init(title: "Muted Codes", value: "\(observer.mutedCodeCount)"),
      .init(title: "Last Sweep", value: formatTimestamp(observer.lastScanTime)),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Observe")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
        .accessibilityAddTraits(.isHeader)
      InspectorFactGrid(facts: facts)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        InspectorSection(title: "Muted Codes") {
          let formatted = mutedCodes.map { $0.replacing("_", with: " ") }
          InspectorBadgeColumn(values: formatted)
        }
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        ObserverOpenIssuesSection(issues: openIssues)
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        ObserverWorkersSection(workers: activeWorkers)
      }
      if let cycleHistory = observer.cycleHistory, !cycleHistory.isEmpty {
        InspectorSection(title: "Cycle History") {
          ObserverCycleHistoryContent(cycles: cycleHistory)
        }
      }
      if let agentSessions = observer.agentSessions, !agentSessions.isEmpty {
        InspectorSection(title: "Tracked Agent Sessions") {
          ObserverAgentSessionsContent(sessions: agentSessions)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.observerInspectorCard,
      label: "Observe",
      value: "\(observer.openIssueCount)"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.observerInspectorCard).frame")
  }
}

struct InspectorObserverSummarySection: View {
  let observer: ObserverSummary

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorActionHeader(
        title: "Observe",
        subtitle: "The observer loop keeps the session moving and surfaces drift."
      )
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        HarnessMonitorBadge(value: "Open \(observer.openIssueCount)")
        HarnessMonitorBadge(value: "Muted \(observer.mutedCodeCount)")
        HarnessMonitorBadge(value: "Workers \(observer.activeWorkerCount)")
      }
      Text("Last sweep \(formatTimestamp(observer.lastScanTime))")
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        Text("Muted codes")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(mutedCodes.prefix(3).joined(separator: " · "))
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        Text("Open issues")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          ForEach(openIssues.prefix(2)) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(issue.code) · \(issue.summary)")
                .scaledFont(.caption)
              Text("Severity \(issue.severity.capitalized)")
                .scaledFont(.caption2)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            }
          }
        }
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        Text("Active workers")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          ForEach(activeWorkers.prefix(2)) { worker in
            VStack(alignment: .leading, spacing: 2) {
              Text(worker.agentId ?? "worker")
                .scaledFont(.caption)
              Text(worker.targetFile)
                .scaledFont(.caption2)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .lineLimit(1)
            }
          }
        }
      }
    }
  }
}

private struct ObserverOpenIssuesSection: View {
  let issues: [ObserverIssueSummary]

  var body: some View {
    InspectorSection(title: "Open Issues") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        ForEach(issues) { issue in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Text(issue.code)
                .scaledFont(.caption.bold())
                .textCase(.uppercase)
              Spacer()
              Text(issue.severity.capitalized)
                .scaledFont(.caption2.bold())
            }
            Text(issue.summary)
              .scaledFont(.subheadline)
            if let evidenceExcerpt = issue.evidenceExcerpt {
              Text(evidenceExcerpt)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .lineLimit(2)
            }
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverWorkersSection: View {
  let workers: [ObserverWorkerSummary]

  var body: some View {
    InspectorSection(title: "Active Workers") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        ForEach(workers) { worker in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(worker.agentId ?? "worker")
                .scaledFont(.subheadline.bold())
              Spacer()
              Text(formatTimestamp(worker.startedAt))
                .scaledFont(.caption.monospaced())
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            }
            Text(worker.targetFile)
              .scaledFont(.caption)
              .truncationMode(.middle)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(2)
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverCycleHistoryContent: View {
  let cycles: [ObserverCycleSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(cycles) { cycle in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(formatTimestamp(cycle.timestamp))
              .scaledFont(.caption.monospaced())
            Spacer()
            Text("+\(cycle.newIssues) / -\(cycle.resolved)")
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
          Text("Lines \(cycle.fromLine) - \(cycle.toLine)")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .harnessCellPadding()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ObserverAgentSessionsContent: View {
  let sessions: [ObserverAgentSessionSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(sessions) { session in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(session.agentId)
              .scaledFont(.subheadline.bold())
            Spacer()
            Text(session.runtime.uppercased())
              .scaledFont(.caption2.bold())
              .tracking(HarnessMonitorTheme.uppercaseTracking)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
          Text("Cursor \(session.cursor)")
            .scaledFont(.caption.monospaced())
          if let lastActivity = session.lastActivity {
            Text("Last activity \(formatTimestamp(lastActivity))")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
          if let logPath = session.logPath {
            Text(logPath)
              .scaledFont(.caption.monospaced())
              .truncationMode(.middle)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(2)
          }
        }
        .harnessCellPadding()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

import HarnessKit
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
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Observe")
        .font(.system(.title3, design: .rounded, weight: .bold))
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
        ObserverCycleHistorySection(cycles: cycleHistory)
      }
      if let agentSessions = observer.agentSessions, !agentSessions.isEmpty {
        ObserverAgentSessionsSection(sessions: agentSessions)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.observerInspectorCard,
      label: "Observe",
      value: "\(observer.openIssueCount)"
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.observerInspectorCard).frame")
  }
}

struct InspectorFact: Identifiable {
  let title: String
  let value: String
  var id: String { title }
}

private struct ObserverOpenIssuesSection: View {
  let issues: [ObserverIssueSummary]

  var body: some View {
    InspectorSection(title: "Open Issues") {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        ForEach(issues) { issue in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Text(issue.code)
                .font(.caption.bold())
                .textCase(.uppercase)
              Spacer()
              Text(issue.severity.capitalized)
                .font(.caption2.bold())
            }
            Text(issue.summary)
              .font(.subheadline)
            if let evidenceExcerpt = issue.evidenceExcerpt {
              Text(evidenceExcerpt)
                .font(.caption)
                .foregroundStyle(HarnessTheme.secondaryInk)
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
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        ForEach(workers) { worker in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(worker.agentId ?? "worker")
                .font(.subheadline.bold())
              Spacer()
              Text(formatTimestamp(worker.startedAt))
                .font(.caption.monospaced())
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            Text(worker.targetFile)
              .font(.caption)
              .truncationMode(.middle)
              .foregroundStyle(HarnessTheme.secondaryInk)
              .lineLimit(2)
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverCycleHistorySection: View {
  let cycles: [ObserverCycleSummary]

  var body: some View {
    InspectorSection(title: "Cycle History") {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        ForEach(cycles) { cycle in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(formatTimestamp(cycle.timestamp))
                .font(.caption.monospaced())
              Spacer()
              Text("+\(cycle.newIssues) / -\(cycle.resolved)")
                .font(.caption.bold())
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            Text("Lines \(cycle.fromLine) - \(cycle.toLine)")
              .font(.caption)
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverAgentSessionsSection: View {
  let sessions: [ObserverAgentSessionSummary]

  var body: some View {
    InspectorSection(title: "Tracked Agent Sessions") {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        ForEach(sessions) { session in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(session.agentId)
                .font(.subheadline.bold())
              Spacer()
              Text(session.runtime.uppercased())
                .font(.caption2.bold())
                .tracking(HarnessTheme.uppercaseTracking)
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            Text("Cursor \(session.cursor)")
              .font(.caption.monospaced())
            if let lastActivity = session.lastActivity {
              Text("Last activity \(formatTimestamp(lastActivity))")
                .font(.caption)
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            if let logPath = session.logPath {
              Text(logPath)
                .font(.caption.monospaced())
                .truncationMode(.middle)
                .foregroundStyle(HarnessTheme.secondaryInk)
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

struct InspectorFactGrid: View {
  let facts: [InspectorFact]

  var body: some View {
    HarnessAdaptiveGridLayout(minimumColumnWidth: 132, maximumColumns: 2, spacing: HarnessTheme.itemSpacing) {
      ForEach(facts) { fact in
        VStack(alignment: .leading, spacing: 4) {
          Text(fact.title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(HarnessTheme.uppercaseTracking)
            .foregroundStyle(HarnessTheme.secondaryInk)
          Text(fact.value)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .harnessCellPadding()
      }
    }
  }
}

struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      Text(title)
        .font(.caption.bold())
        .foregroundStyle(HarnessTheme.secondaryInk)
      content
    }
  }
}

struct InspectorBadgeColumn: View {
  let values: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Text(value)
          .font(.caption.weight(.semibold))
          .harnessPillPadding()
          .harnessInfoPill()
      }
    }
  }
}

struct InspectorObserverSummarySection: View {
  let observer: ObserverSummary

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      HarnessActionHeader(
        title: "Observe",
        subtitle: "The observer loop keeps the session moving and surfaces drift."
      )
      HStack(spacing: HarnessTheme.itemSpacing) {
        HarnessBadge(value: "Open \(observer.openIssueCount)")
        HarnessBadge(value: "Muted \(observer.mutedCodeCount)")
        HarnessBadge(value: "Workers \(observer.activeWorkerCount)")
      }
      Text("Last sweep \(formatTimestamp(observer.lastScanTime))")
        .font(.caption.monospaced())
        .foregroundStyle(HarnessTheme.secondaryInk)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        Text("Muted codes")
          .font(.caption.bold())
          .foregroundStyle(HarnessTheme.secondaryInk)
        Text(mutedCodes.prefix(3).joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        Text("Open issues")
          .font(.caption.bold())
          .foregroundStyle(HarnessTheme.secondaryInk)
        VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
          ForEach(openIssues.prefix(2)) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(issue.code) · \(issue.summary)")
                .font(.caption)
              Text("Severity \(issue.severity.capitalized)")
                .font(.caption2)
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
          }
        }
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        Text("Active workers")
          .font(.caption.bold())
          .foregroundStyle(HarnessTheme.secondaryInk)
        VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
          ForEach(activeWorkers.prefix(2)) { worker in
            VStack(alignment: .leading, spacing: 2) {
              Text(worker.agentId ?? "worker")
                .font(.caption)
              Text(worker.targetFile)
                .font(.caption2)
                .foregroundStyle(HarnessTheme.secondaryInk)
                .lineLimit(1)
            }
          }
        }
      }
    }
  }
}

extension JSONValue {
  private static let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  func prettyPrintedJSONString() -> String {
    guard let data = try? Self.prettyEncoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return string
  }
}

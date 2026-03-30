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
    VStack(alignment: .leading, spacing: 12) {
      Text("Observe")
        .font(.system(.title3, design: .rounded, weight: .bold))
      InspectorFactGrid(facts: facts)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        InspectorSection(title: "Muted Codes") {
          let formatted = mutedCodes.map { $0.replacing("_", with: " ") }
          InspectorBadgeColumn(values: formatted)
        }
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        InspectorSection(title: "Open Issues") {
          HarnessGlassContainer(spacing: 8) {
            ForEach(openIssues) { issue in
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
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .harnessInsetPanel(cornerRadius: 14, fillOpacity: 0.05, strokeOpacity: 0.10)
            }
          }
        }
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        InspectorSection(title: "Active Workers") {
          HarnessGlassContainer(spacing: 8) {
            ForEach(activeWorkers) { worker in
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
                  .foregroundStyle(HarnessTheme.secondaryInk)
                  .lineLimit(2)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .harnessInsetPanel(cornerRadius: 14, fillOpacity: 0.05, strokeOpacity: 0.10)
            }
          }
        }
      }
      if let cycleHistory = observer.cycleHistory, !cycleHistory.isEmpty {
        InspectorSection(title: "Cycle History") {
          HarnessGlassContainer(spacing: 8) {
            ForEach(cycleHistory) { cycle in
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
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .harnessInsetPanel(cornerRadius: 14, fillOpacity: 0.05, strokeOpacity: 0.10)
            }
          }
        }
      }
      if let agentSessions = observer.agentSessions, !agentSessions.isEmpty {
        InspectorSection(title: "Tracked Agent Sessions") {
          HarnessGlassContainer(spacing: 8) {
            ForEach(agentSessions) { session in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(session.agentId)
                    .font(.subheadline.bold())
                  Spacer()
                  Text(session.runtime.uppercased())
                    .font(.caption2.bold())
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
                    .foregroundStyle(HarnessTheme.secondaryInk)
                    .lineLimit(2)
                }
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .harnessInsetPanel(cornerRadius: 14, fillOpacity: 0.05, strokeOpacity: 0.10)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.observerInspectorCard)
    .accessibilityFrameMarker("\(HarnessAccessibility.observerInspectorCard).frame")
  }
}

struct InspectorFact: Identifiable {
  let title: String
  let value: String

  var id: String { "\(title):\(value)" }
}

struct InspectorFactGrid: View {
  let facts: [InspectorFact]

  var body: some View {
    HarnessAdaptiveGridLayout(minimumColumnWidth: 132, maximumColumns: 2, spacing: 10) {
      ForEach(facts) { fact in
        VStack(alignment: .leading, spacing: 3) {
          Text(fact.title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(HarnessTheme.secondaryInk)
          Text(fact.value)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .harnessInsetPanel(cornerRadius: 14, fillOpacity: 0.05, strokeOpacity: 0.10)
      }
    }
  }
}

struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
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
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Text(value)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background {
            HarnessGlassCapsuleBackground()
          }
      }
    }
  }
}

struct InspectorObserverSummarySection: View {
  let observer: ObserverSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      harnessActionHeader(
        title: "Observe",
        subtitle: "The observer loop keeps the session moving and surfaces drift."
      )
      HStack {
        harnessBadge("Open \(observer.openIssueCount)")
        harnessBadge("Muted \(observer.mutedCodeCount)")
        harnessBadge("Workers \(observer.activeWorkerCount)")
      }
      Text("Last sweep \(formatTimestamp(observer.lastScanTime))")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        Text("Muted codes")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
        Text(mutedCodes.prefix(3).joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        Text("Open issues")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(openIssues.prefix(2)) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(issue.code) · \(issue.summary)")
                .font(.caption)
              Text("Severity \(issue.severity.capitalized)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        Text("Active workers")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(activeWorkers.prefix(2)) { worker in
            VStack(alignment: .leading, spacing: 2) {
              Text(worker.agentId ?? "worker")
                .font(.caption)
              Text(worker.targetFile)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
    }
    .harnessCard()
  }
}

extension JSONValue {
  func prettyPrintedJSONString() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return string
  }
}

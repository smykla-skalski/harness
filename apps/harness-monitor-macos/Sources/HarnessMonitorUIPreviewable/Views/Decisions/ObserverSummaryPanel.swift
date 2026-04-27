import HarnessMonitorKit
import SwiftUI

public struct ObserverSummaryPanel: View {
  public let observer: ObserverSummary

  public init(observer: ObserverSummary) {
    self.observer = observer
  }

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

  public var body: some View {
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
        ObserverPanelOpenIssuesSection(issues: openIssues)
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        ObserverPanelWorkersSection(workers: activeWorkers)
      }
      if let agentSessions = observer.agentSessions, !agentSessions.isEmpty {
        InspectorSection(title: "Tracked Agent Sessions") {
          ObserverPanelAgentSessions(sessions: agentSessions)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.decisionsObserverPanel,
      label: "Observe",
      value: "\(observer.openIssueCount)"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.decisionsObserverPanel).frame")
  }
}

public struct ObserverSummaryEmptyState: View {
  public init() {}

  public var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "eye.slash")
        .font(.system(size: 28))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("No observer for this session")
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      Text("The observer surfaces open issues, muted codes, and worker activity once it has data.")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .multilineTextAlignment(.center)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .center)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsObserverEmptyState)
  }
}

#Preview("Observer summary panel") {
  ObserverSummaryPanel(observer: PreviewFixtures.observer)
    .padding()
    .frame(width: 560)
}

#Preview("Observer empty state") {
  ObserverSummaryEmptyState()
    .padding()
    .frame(width: 560)
}

private struct ObserverPanelOpenIssuesSection: View {
  let issues: [ObserverIssueSummary]

  var body: some View {
    InspectorSection(title: "Recent Findings") {
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

private struct ObserverPanelWorkersSection: View {
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

private struct ObserverPanelAgentSessions: View {
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

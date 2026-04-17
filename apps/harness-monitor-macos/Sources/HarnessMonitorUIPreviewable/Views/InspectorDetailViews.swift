import HarnessMonitorKit
import SwiftUI

public struct SessionInspectorSummaryCard: View {
  public let detail: SessionDetail

  public init(detail: SessionDetail) {
    self.detail = detail
  }

  private var facts: [InspectorFact] {
    [
      .init(title: "Leader", value: detail.session.leaderId ?? "n/a"),
      .init(title: "Last Activity", value: formatTimestamp(detail.session.lastActivityAt)),
      .init(title: "Open Tasks", value: "\(detail.session.metrics.openTaskCount)"),
      .init(title: "Active Agents", value: "\(detail.session.metrics.activeAgentCount)"),
    ]
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Inspector")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(
        "Pick a task, agent, signal, or observe card from the cockpit to focus actions and detail here."
      )
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      InspectorFactGrid(facts: facts)
      if !detail.agentActivity.isEmpty {
        InspectorSection(title: "Recent Agent Activity") {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(detail.agentActivity.prefix(2)) { activity in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(activity.agentId)
                    .scaledFont(.system(.subheadline, design: .rounded, weight: .semibold))
                  Spacer()
                  Text(activity.latestEventAt.map(formatTimestamp) ?? "No events")
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                }
                Text(activity.recentTools.joined(separator: " · "))
                  .scaledFont(.caption)
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sessionInspectorCard,
      label: "Inspector",
      value: detail.session.sessionId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sessionInspectorCard).frame")
  }
}

public struct SignalInspectorCard: View {
  public let signal: SessionSignalRecord

  public init(signal: SessionSignalRecord) {
    self.signal = signal
  }

  private static let expiresInStyle: Date.RelativeFormatStyle = .relative(
    presentation: .numeric,
    unitsStyle: .wide
  )

  private var effectiveStatus: SessionSignalStatus { signal.effectiveStatus }

  private var pendingExpiresAt: Date? {
    guard effectiveStatus == .pending, let expires = signal.expiresAtDate, expires > .now else {
      return nil
    }
    return expires
  }

  private var facts: [InspectorFact] {
    [
      .init(title: "Status", value: effectiveStatus.title),
      .init(title: "Agent", value: signal.agentId),
      .init(title: "Runtime", value: signal.runtime),
      .init(title: "Priority", value: signal.signal.priority.title),
      .init(title: "Created", value: formatTimestamp(signal.signal.createdAt)),
      .init(title: "Expires", value: formatTimestamp(signal.signal.expiresAt)),
    ]
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text(signal.signal.command)
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      HarnessMonitorMarkdownText(
        signal.signal.payload.message,
        textSelection: .enabled
      )
      InspectorFactGrid(facts: facts)
      if let expires = pendingExpiresAt {
        Label {
          Text("Expires \(expires, format: Self.expiresInStyle)")
        } icon: {
          Image(systemName: "clock")
        }
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityLabel("Expires \(expires, format: Self.expiresInStyle)")
      }
      if let actionHint = signal.signal.payload.actionHint, !actionHint.isEmpty {
        InspectorSection(title: "Action Hint") {
          Text(actionHint)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
      if !signal.signal.payload.relatedFiles.isEmpty {
        DisclosureGroup("Related Files") {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(
              Array(signal.signal.payload.relatedFiles.enumerated()),
              id: \.offset
            ) { _, path in
              Text(path)
                .scaledFont(.caption.monospaced())
                .truncationMode(.middle)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if !signal.signal.payload.metadata.isStructurallyEmpty {
        DisclosureGroup("Metadata") {
          Text(verbatim: signal.signal.payload.metadata.prettyPrintedJSONString())
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if let acknowledgment = signal.acknowledgment {
        InspectorSection(title: "Acknowledgment") {
          InspectorFactGrid(
            facts: [
              .init(title: "Result", value: acknowledgment.result.title),
              .init(title: "Agent", value: acknowledgment.agent),
              .init(title: "At", value: formatTimestamp(acknowledgment.acknowledgedAt)),
            ]
          )
          if let details = acknowledgment.details, !details.isEmpty {
            Text(details)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.signalInspectorCard,
      label: signal.signal.command,
      value: signal.signal.signalId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.signalInspectorCard).frame")
  }
}

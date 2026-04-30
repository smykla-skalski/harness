import HarnessMonitorKit
import SwiftUI

/// Inspector column for the Decisions window. Hosts the metadata grid that mirrors the hero
/// chips in scannable `LabeledContent` rows plus the live tick. Toggled from the window toolbar
/// and persisted via `@AppStorage` on `DecisionsWindowView`.
@MainActor
public struct DecisionInspector: View {
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  private let decision: Decision?
  private let liveTick: DecisionLiveTickSnapshot
  @State private var showIdentifierDetails = false

  public init(
    decision: Decision? = nil,
    liveTick: DecisionLiveTickSnapshot = .placeholder
  ) {
    self.decision = decision
    self.liveTick = liveTick
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        if let decision {
          metadataGrid(decision)
        } else {
          emptyState
        }
        liveTickSection
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionInspector)
  }

  private func metadataGrid(_ decision: Decision) -> some View {
    let severity = DecisionSeverity(rawValue: decision.severityRaw) ?? .info
    let createdLabel = formatTimestamp(decision.createdAt, configuration: dateTimeConfiguration)
    let snoozeLabel: String? = decision.snoozedUntil.map {
      formatTimestamp($0, configuration: dateTimeConfiguration)
    }
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Metadata")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        metadataRow("Severity", value: severityTitle(severity))
        metadataRow("Status", value: decision.statusRaw.capitalized)
        metadataRow("Created", value: createdLabel, monospaced: true)
        if let snoozeLabel {
          metadataRow("Snoozed Until", value: snoozeLabel, monospaced: true)
        }
        if hasIdentifierDetails(decision) {
          DisclosureGroup("Identifiers", isExpanded: $showIdentifierDetails) {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
              metadataRow("Rule", value: decision.ruleID, monospaced: true)
              if let sessionID = nonEmpty(decision.sessionID) {
                metadataRow("Session", value: sessionID, monospaced: true)
              }
              if let agentID = nonEmpty(decision.agentID) {
                metadataRow("Agent", value: agentID, monospaced: true)
              }
              if let taskID = nonEmpty(decision.taskID) {
                metadataRow("Task", value: taskID, monospaced: true)
              }
            }
            .padding(.top, HarnessMonitorTheme.spacingXS)
          }
          .scaledFont(.caption)
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionInspectorMetadata)
    }
  }

  private func hasIdentifierDetails(_ decision: Decision) -> Bool {
    nonEmpty(decision.sessionID) != nil
      || nonEmpty(decision.agentID) != nil
      || nonEmpty(decision.taskID) != nil
      || !decision.ruleID.isEmpty
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func metadataRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
    LabeledContent {
      let textValue = Text(value)
        .scaledFont(.callout)
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
      if monospaced {
        textValue.monospaced()
      } else {
        textValue
      }
    } label: {
      Text(label)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var liveTickSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Live Tick")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      DecisionsLiveTickView(snapshot: liveTick, chrome: false)
    }
  }

  private func severityTitle(_ severity: DecisionSeverity) -> String {
    switch severity {
    case .info: "Info"
    case .warn: "Warning"
    case .needsUser: "Needs User"
    case .critical: "Critical"
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("No decision selected")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Select a decision from the sidebar to inspect metadata.")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }
}

#Preview("Decision Inspector — empty") {
  DecisionInspector()
    .frame(width: 320, height: 480)
}

import HarnessMonitorKit
import SwiftUI

struct SignalDetailSheet: View {
  let store: HarnessMonitorStore
  let signalID: String
  @Environment(\.dismiss)
  private var dismiss

  private var signal: SessionSignalRecord? {
    store.selectedSession?.signals.first { $0.signal.signalId == signalID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let signal {
        header(for: signal)
        Divider()
        ScrollView {
          SignalDetailCard(signal: signal)
            .padding(HarnessMonitorTheme.spacingLG)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        unavailableState
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.signalDetailSheet)
    .onChange(of: signal == nil) { _, missing in
      if missing { dismiss() }
    }
  }

  private func header(for signal: SessionSignalRecord) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Signal")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(signal.signal.command)
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      }
      Spacer()
      Button("Done") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.signalDetailDismissButton)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var unavailableState: some View {
    VStack(spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Signal unavailable.")
        .scaledFont(.headline)
      Button("Dismiss") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.signalDetailDismissButton)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct SignalDetailCard: View {
  let signal: SessionSignalRecord

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

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
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
      HarnessMonitorAccessibility.signalDetailCard,
      label: signal.signal.command,
      value: signal.signal.signalId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.signalDetailCard).frame")
  }
}

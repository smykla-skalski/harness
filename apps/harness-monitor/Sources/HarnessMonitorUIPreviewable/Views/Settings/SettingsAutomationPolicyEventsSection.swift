import SwiftUI

struct SettingsAutomationPolicyEventsSection: View {
  let policyCenter: AutomationPolicyCenter

  var body: some View {
    Section {
      if policyCenter.recentAutomationEvents.isEmpty {
        Text("No automation events recorded")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        ForEach(Array(policyCenter.recentAutomationEvents.prefix(12))) { event in
          SettingsAutomationPolicyEventRow(event: event)
        }
        Button {
          policyCenter.clearAutomationEvents()
        } label: {
          Label("Clear Events", systemImage: "trash")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      }
    } header: {
      Text("Recent Events")
    } footer: {
      Text(
        """
        Events show which policy matched, what was skipped, and the safe metadata \
        captured after privacy checks passed.
        """
      )
    }
  }
}

private struct SettingsAutomationPolicyEventRow: View {
  let event: AutomationPolicyEventRecord

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(alignment: .firstTextBaseline) {
        Label(event.outcome.title, systemImage: systemImage)
          .foregroundStyle(tint)
        Spacer()
        Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      }
      Text(event.policyName ?? event.source.title)
        .scaledFont(.callout.weight(.semibold))
        .lineLimit(1)
      Text(event.summary)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
      if let reason = event.reason {
        Text(reason)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      }
      metadataPreview
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .contextMenu {
      Button("Copy Summary") {
        HarnessMonitorClipboard.copy(copySummary)
      }
    }
  }

  @ViewBuilder private var metadataPreview: some View {
    if let textPreview = event.textPreview, !textPreview.isEmpty {
      Text(textPreview)
        .scaledFont(.caption2.monospaced())
        .lineLimit(3)
        .textSelection(.enabled)
        .padding(HarnessMonitorTheme.spacingSM)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HarnessMonitorTheme.ink.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    }
    if !event.filePaths.isEmpty {
      Text(event.filePaths.joined(separator: "\n"))
        .scaledFont(.caption2.monospaced())
        .lineLimit(3)
        .textSelection(.enabled)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var systemImage: String {
    switch event.outcome {
    case .matched: "checkmark.circle"
    case .skipped: "forward.end"
    case .denied: "hand.raised"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var tint: Color {
    switch event.outcome {
    case .matched: HarnessMonitorTheme.success
    case .skipped: HarnessMonitorTheme.secondaryInk
    case .denied, .failed: HarnessMonitorTheme.danger
    }
  }

  private var copySummary: String {
    [
      event.occurredAt.formatted(date: .abbreviated, time: .standard),
      event.source.title,
      event.outcome.title,
      event.policyName,
      event.summary,
      event.reason,
      event.textPreview,
      event.filePaths.joined(separator: "\n"),
    ]
    .compactMap { value -> String? in
      guard let value, !value.isEmpty else {
        return nil
      }
      return value
    }
    .joined(separator: "\n")
  }
}

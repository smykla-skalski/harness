import HarnessMonitorKit
import SwiftUI

struct AgentDetailPanel<Content: View>: View {
  let title: String?
  private let content: Content

  init(
    title: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      if let title {
        Text(title)
          .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .accessibilityAddTraits(.isHeader)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AgentDetailInsetGroup<Content: View>: View {
  let title: String
  private let content: Content

  init(
    title: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      AgentDetailSubsectionTitle(title: title)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct AgentDetailSummaryHeader: View {
  let title: String
  let runtimeLabel: String
  let status: AgentStatus
  let statusLabel: String
  let roleTitle: String
  let currentTaskTitle: String
  let overviewFacts: [AgentDetailFact]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
        statusChip
        runtimeChip
        roleChip
        Spacer(minLength: 0)
      }
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Current Task")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityAddTraits(.isHeader)
        Text(currentTaskTitle)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
          .fixedSize(horizontal: false, vertical: true)
      }

      if !overviewFacts.isEmpty {
        AgentDetailHeaderFactStrip(facts: overviewFacts)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusChip: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: statusSymbol)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(agentStatusColor(for: status))
        .accessibilityHidden(true)
      Text(statusLabel)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(agentStatusColor(for: status))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status")
    .accessibilityValue(statusLabel)
  }

  private var runtimeChip: some View {
    Text(runtimeLabel)
      .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Runtime")
      .accessibilityValue(runtimeLabel)
  }

  private var roleChip: some View {
    Text(roleTitle)
      .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Role")
      .accessibilityValue(roleTitle)
  }

  private var statusSymbol: String {
    switch status {
    case .active:
      "checkmark.circle.fill"
    case .awaitingReview:
      "eye.circle.fill"
    case .idle:
      "pause.circle.fill"
    case .disconnected:
      "bolt.horizontal.circle.fill"
    case .removed:
      "minus.circle.fill"
    }
  }
}

struct AgentDetailOperationalSummary: View {
  let title: String
  let summary: String
  let nextStep: String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      Text(summary)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      Text(nextStep)
        .scaledFont(.footnote.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

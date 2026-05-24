import HarnessMonitorKit
import SwiftUI

/// Popover surface that surfaces the chip vocabulary previously rendered
/// inline in the provenance card: cache window, repo refresh cadence,
/// repo count, plus the now-stacked warnings and the per-repository
/// names that are otherwise buried in `DashboardReviewsSyncHealth`.
struct DashboardReviewsProvenancePopover: View {
  let snapshot: DashboardReviewsProvenanceSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      header
      Divider()
      metricsSection
      if !snapshot.warnings.isEmpty {
        Divider()
        warningsSection
      }
      if !snapshot.failedRepositories.isEmpty {
        Divider()
        repositoryGroup(
          title: "Sync failed",
          repositories: snapshot.failedRepositories,
          tint: HarnessMonitorTheme.danger
        )
      }
      if !snapshot.staleRepositories.isEmpty {
        Divider()
        repositoryGroup(
          title: "Sync stale",
          repositories: snapshot.staleRepositories,
          tint: HarnessMonitorTheme.caution
        )
      }
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(width: 340)
    .frame(minHeight: 360, alignment: .top)
    .harnessFloatingControlGlass(cornerRadius: 12, tint: snapshot.sourceTint)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Review data details")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Circle()
        .fill(snapshot.sourceTint)
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
      Text(snapshot.sourceTitle)
        .scaledFont(.headline)
        .foregroundStyle(snapshot.sourceTint)
        .accessibilityAddTraits(.isHeader)
    }
  }

  private var metricsSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      metricRow(
        title: "Last fetched",
        primary: snapshot.fetchedAtTitle,
        secondary: snapshot.fetchedDate == nil ? nil : snapshot.fetchedAgeTitle
      )
      metricRow(
        title: "Freshness ceiling",
        primary: harnessMonitorDuration(snapshot.freshnessCeilingSeconds),
        secondary:
          "cache \(harnessMonitorDuration(snapshot.cacheMaxAgeSeconds)) · "
          + "sync \(harnessMonitorDuration(snapshot.perRepositoryIntervalSeconds))"
      )
      metricRow(
        title: "Repositories",
        primary: "\(snapshot.repositoryCount) tracked",
        secondary: snapshot.syncingRepositoryCount > 0
          ? "\(snapshot.syncingRepositoryCount) syncing" : nil
      )
    }
  }

  private func metricRow(title: String, primary: String, secondary: String?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      Text(primary)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.ink)
      if let secondary {
        Text(secondary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var warningsSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Warnings")
        .scaledFont(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      ForEach(snapshot.warnings, id: \.self) { message in
        Label(message, systemImage: "exclamationmark.triangle")
          .scaledFont(.callout.weight(.medium))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .lineLimit(3)
          .accessibilityLabel(message)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func repositoryGroup(
    title: String,
    repositories: [String],
    tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      let visibleRepositories = repositories.prefix(5)
      let remainder = repositories.count - visibleRepositories.count
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingXS,
        lineSpacing: HarnessMonitorTheme.spacingXS
      ) {
        ForEach(visibleRepositories, id: \.self) { name in
          Text(name)
            .scaledFont(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .harnessOpticallyBalancedVerticalPadding(3)
            .harnessControlPillGlass(tint: tint)
        }
        if remainder > 0 {
          Text("+\(remainder) more")
            .scaledFont(.caption.weight(.medium))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .padding(.horizontal, 8)
            .harnessOpticallyBalancedVerticalPadding(3)
            .harnessControlPillGlass(tint: HarnessMonitorTheme.controlBorder)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

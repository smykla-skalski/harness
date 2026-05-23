import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  /// Transient banner zone consumed by Unit 7's refresh-timeout retry signal
  /// and Unit 10's disappeared-item descriptors. Banners render in source
  /// order, are individually dismissible, and disappear once their backing
  /// state clears.
  @ViewBuilder var transientBannerZone: some View {
    if routeRefreshTimeoutItems != nil || !routeDisappearedDescriptors.isEmpty {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if let timeoutItems = routeRefreshTimeoutItems {
          refreshTimeoutBanner(items: timeoutItems)
        }
        ForEach(routeDisappearedDescriptors) { descriptor in
          disappearedItemBanner(descriptor: descriptor)
        }
      }
      .transition(.opacity)
    }
  }

  /// Inline retry banner for the targeted-refresh timeout path. Tapping the
  /// label re-runs `scheduleAffectedRefresh` for the same items; the close
  /// affordance dismisses the banner without retrying.
  func refreshTimeoutBanner(items: [ReviewItem]) -> some View {
    let label =
      items.count == 1
      ? "Refresh for 1 pull request timed out."
      : "Refresh for \(items.count) pull requests timed out."
    return HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityHidden(true)
      Text(label)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button("Retry") {
        routeRefreshTimeoutItems = nil
        if let client = store.apiClient {
          scheduleAffectedRefresh(for: items, using: client)
        }
      }
      .buttonStyle(.borderless)
      Button {
        routeRefreshTimeoutItems = nil
      } label: {
        Image(systemName: "xmark.circle.fill")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss refresh-timeout banner")
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(HarnessMonitorTheme.caution.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.caution.opacity(0.24), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label) Tap retry to try again.")
  }

  /// One-shot banner for a pull request that vanished from the latest
  /// response (merged, closed, or otherwise dropped). Dismiss removes the
  /// descriptor from the shared queue.
  func disappearedItemBanner(
    descriptor: DashboardReviewsDisappearedItemTracker.Descriptor
  ) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      Text(descriptor.toastMessage)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button {
        routeDisappearedDescriptors.removeAll { $0.id == descriptor.id }
      } label: {
        Image(systemName: "xmark.circle.fill")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss \(descriptor.toastMessage)")
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(HarnessMonitorTheme.secondaryInk.opacity(0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.secondaryInk.opacity(0.20), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(descriptor.toastMessage)
  }
}

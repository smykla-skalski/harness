import HarnessMonitorKit
import SwiftUI

extension DashboardReviewsRouteView {
  /// Transient banner zone consumed by Unit 7's refresh-timeout retry signal.
  /// The low-priority disappeared-item notices now go straight to audit via
  /// notification history instead of adding more inline chrome here.
  @ViewBuilder var transientBannerZone: some View {
    if routeRefreshTimeoutItems != nil {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if let timeoutItems = routeRefreshTimeoutItems {
          refreshTimeoutBanner(items: timeoutItems)
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
      .harnessPlainButtonStyle()
      Button {
        routeRefreshTimeoutItems = nil
      } label: {
        Image(systemName: "xmark.circle.fill")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .harnessPlainButtonStyle()
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
}

import HarnessMonitorKit
import SwiftUI

enum DashboardReviewsRefreshTimeoutAction: Equatable {
  case retry
  case dismiss
}

struct DashboardReviewsRefreshTimeoutBanner: View {
  let itemCount: Int
  @Binding var action: DashboardReviewsRefreshTimeoutAction?

  private var label: String {
    itemCount == 1
      ? "Refresh for 1 pull request timed out."
      : "Refresh for \(itemCount) pull requests timed out."
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityHidden(true)
      Text(label)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button("Retry") {
        action = .retry
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .controlSize(.small)
      Button {
        action = .dismiss
      } label: {
        Image(systemName: "xmark.circle.fill")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .harnessPlainButtonStyle()  // monitor-perf: plain-button review-refresh-timeout-dismiss
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
    .accessibilityElement(children: .contain)
  }
}

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

  /// Inline retry banner for the targeted-refresh timeout path. Retry re-runs
  /// `scheduleAffectedRefresh` for the same items; the close affordance
  /// dismisses the banner without retrying.
  func refreshTimeoutBanner(items: [ReviewItem]) -> some View {
    let action = Binding<DashboardReviewsRefreshTimeoutAction?>(
      get: { nil },
      set: { action in
        guard let action else { return }
        routeRefreshTimeoutItems = nil
        if action == .retry, let client = store.apiClient {
          scheduleAffectedRefresh(for: items, using: client)
        }
      }
    )
    return DashboardReviewsRefreshTimeoutBanner(itemCount: items.count, action: action)
  }
}

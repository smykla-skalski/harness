import HarnessMonitorKit
import SwiftUI

let dependenciesDetailMaxWidth: CGFloat = 940

extension DashboardDependenciesRouteView {
  func detailCard<Content: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      Text(subtitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
    .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
    .padding(.bottom, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.42)
    }
  }

  func detailSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let title {
        Text(title)
          .scaledFont(.headline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      content()
    }
    .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .top) {
      Divider().opacity(0.34)
    }
  }

  func actionButton(
    _ title: String,
    systemImage: String,
    prominence: DashboardDependencyActionProminence = .utility,
    action: @escaping () -> Void
  )
    -> some View
  {
    DashboardDependencyActionButton(
      title: title,
      systemImage: systemImage,
      prominence: prominence,
      action: action
    )
  }

  func errorState(message: String) -> some View {
    ContentUnavailableView {
      Label("Dependencies unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Open Secrets") {
        openSettingsSection(.secrets)
      }
      Button("Open Sources Settings") {
        openSettingsSection(.repositories)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

import HarnessMonitorKit
import SwiftUI

private enum DashboardDependencyTitleLineCenterAlignment: AlignmentID {
  static func defaultValue(in context: ViewDimensions) -> CGFloat {
    context[VerticalAlignment.center]
  }
}

extension VerticalAlignment {
  fileprivate static let dashboardDependencyTitleLineCenter = VerticalAlignment(
    DashboardDependencyTitleLineCenterAlignment.self
  )
}

struct DashboardDependencyListRow: View {
  let item: DependencyUpdateItem
  let showsRepository: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String

  var body: some View {
    HStack(alignment: .dashboardDependencyTitleLineCenter, spacing: HarnessMonitorTheme.spacingSM) {
      leadingStatusIndicator

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
          .truncationMode(.tail)
          .alignmentGuide(.dashboardDependencyTitleLineCenter) { dimensions in
            dimensions[VerticalAlignment.center]
          }

        Text(secondaryText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .layoutPriority(1)
    }
    .padding(.horizontal, DashboardDependenciesVisualMetrics.dependencyRowHorizontalPadding)
    .padding(.vertical, DashboardDependenciesVisualMetrics.dependencyRowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Divider()
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var leadingStatusIndicator: some View {
    ZStack {
      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .tint(item.statusTint)
          .accessibilityLabel(progressAccessibilityLabel)
          .transition(.opacity)
      } else {
        Image(systemName: item.statusSystemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(item.statusTint)
          .accessibilityHidden(true)
          .transition(.opacity)
      }
    }
    .frame(width: 18, alignment: .center)
  }

  private var progressAccessibilityLabel: String {
    if let actionTitle, !actionTitle.isEmpty {
      "\(actionTitle) pull request"
    } else {
      "Working on pull request"
    }
  }

  private var secondaryText: String {
    let scopedPullRequest =
      showsRepository
      ? "\(item.repository) #\(item.number)"
      : "#\(item.number)"
    return [scopedPullRequest, item.statusLabel, item.reviewStatus.label, updatedLabel]
      .joined(separator: " · ")
  }
}

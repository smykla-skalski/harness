import HarnessMonitorKit
import SwiftUI

struct SidebarSessionListLinkRow: View, Equatable {
  let session: SessionSummary
  let isBookmarked: Bool
  let isSelected: Bool

  var body: some View {
    SidebarSessionRow(
      session: session,
      isBookmarked: isBookmarked
    )
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .fill(.selection.opacity(0.18))
      }
    }
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.session == rhs.session
      && lhs.isBookmarked == rhs.isBookmarked
      && lhs.isSelected == rhs.isSelected
  }
}

struct SidebarEmptyState: View {
  let title: String
  let systemImage: String
  let message: String

  var body: some View {
    VStack {
      ContentUnavailableView {
        Label(title, systemImage: systemImage)
      } description: {
        Text(message)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(HarnessMonitorTheme.sectionSpacing)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarEmptyStateFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarEmptyState)
  }
}

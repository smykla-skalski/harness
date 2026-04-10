import HarnessMonitorKit
import SwiftUI

struct SidebarSessionListLinkRow: View, Equatable {
  let session: SessionSummary
  let isBookmarked: Bool
  let lastActivityText: String
  let fontScale: CGFloat

  var body: some View {
    SidebarSessionRow(
      session: session,
      isBookmarked: isBookmarked,
      lastActivityText: lastActivityText,
      fontScale: fontScale
    )
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.session == rhs.session
      && lhs.isBookmarked == rhs.isBookmarked
      && lhs.lastActivityText == rhs.lastActivityText
      && lhs.fontScale == rhs.fontScale
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

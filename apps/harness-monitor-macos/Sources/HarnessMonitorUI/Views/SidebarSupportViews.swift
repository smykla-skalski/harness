import HarnessMonitorKit
import SwiftUI

struct SidebarSessionListLinkRow: View, Equatable {
  let session: SessionSummary
  let isBookmarked: Bool

  var body: some View {
    SidebarSessionRow(
      session: session,
      isBookmarked: isBookmarked
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.session == rhs.session
      && lhs.isBookmarked == rhs.isBookmarked
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

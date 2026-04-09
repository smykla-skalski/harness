import HarnessMonitorKit
import SwiftUI

struct SidebarSessionListLinkRow: View {
  let session: SessionSummary
  let isBookmarked: Bool
  let isSelected: Bool

  @State private var isHovered = false

  var body: some View {
    // Counter the extra child indentation applied by the outline so the
    // session status bar lines up with the worktree icon column.
    SidebarSessionRow(
      session: session,
      isBookmarked: isBookmarked,
      isSelected: isSelected,
      isHovered: isHovered
    )
    .padding(.leading, -HarnessMonitorTheme.sectionSpacing)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
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
    .listRowInsets(
      EdgeInsets(
        top: HarnessMonitorTheme.spacingXS,
        leading: HarnessMonitorTheme.sectionSpacing,
        bottom: HarnessMonitorTheme.spacingXS,
        trailing: HarnessMonitorTheme.sectionSpacing
      )
    )
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarEmptyStateFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarEmptyState)
  }
}

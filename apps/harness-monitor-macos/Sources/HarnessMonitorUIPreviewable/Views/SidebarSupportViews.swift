import HarnessMonitorKit
import SwiftUI

public struct SidebarSessionListLinkRow: View, Equatable {
  public let session: SessionSummary
  public let presentation: HarnessMonitorStore.SessionSummaryPresentation
  public let isBookmarked: Bool
  public let lastActivityText: String
  public let fontScale: CGFloat

  public init(
    session: SessionSummary,
    presentation: HarnessMonitorStore.SessionSummaryPresentation,
    isBookmarked: Bool,
    lastActivityText: String,
    fontScale: CGFloat
  ) {
    self.session = session
    self.presentation = presentation
    self.isBookmarked = isBookmarked
    self.lastActivityText = lastActivityText
    self.fontScale = fontScale
  }

  public var body: some View {
    SidebarSessionRow(
      session: session,
      presentation: presentation,
      isBookmarked: isBookmarked,
      lastActivityText: lastActivityText,
      fontScale: fontScale
    )
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.session == rhs.session
      && lhs.presentation == rhs.presentation
      && lhs.isBookmarked == rhs.isBookmarked
      && lhs.lastActivityText == rhs.lastActivityText
      && lhs.fontScale == rhs.fontScale
  }
}

public struct SidebarEmptyState: View {
  public let title: String
  public let systemImage: String
  public let message: String

  public init(title: String, systemImage: String, message: String) {
    self.title = title
    self.systemImage = systemImage
    self.message = message
  }

  public var body: some View {
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

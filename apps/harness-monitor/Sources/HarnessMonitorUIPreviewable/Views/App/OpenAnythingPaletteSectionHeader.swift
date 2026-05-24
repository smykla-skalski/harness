import HarnessMonitorKit
import SwiftUI

/// Section header used by the palette's results list. Renders the domain
/// icon + label + count, plus the collapse chevron and the "Show all"
/// affordance when the section is capped.
struct OpenAnythingPaletteSectionHeader: View {
  let title: String
  let systemImage: String
  let visibleCount: Int
  let totalCount: Int
  let isCollapsed: Bool
  let isExpanded: Bool
  let onToggleCollapse: () -> Void
  let onToggleExpand: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      collapseButton
      Spacer()
      showAllButton
    }
    .padding(.horizontal, OpenAnythingPaletteConstants.sectionHeaderHorizontalPadding)
    .padding(.vertical, OpenAnythingPaletteConstants.sectionHeaderVerticalPadding)
    .background(
      HarnessMonitorTheme.ink
        .opacity(OpenAnythingPaletteConstants.sectionHeaderFillOpacity)
    )
  }

  private var collapseButton: some View {
    Button(action: onToggleCollapse) {
      HStack(spacing: 6) {
        collapseChevron
        Image(systemName: systemImage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(title.uppercased())
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        countLabel
      }
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityHint(isCollapsed ? "Expand section" : "Collapse section")
  }

  private var collapseChevron: some View {
    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
      .font(.caption2)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(width: 10)
      .accessibilityHidden(true)
  }

  private var countLabel: some View {
    Text(countLabelText)
      .font(.caption)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
  }

  private var countLabelText: String {
    if isExpanded || visibleCount == totalCount {
      return "· \(totalCount)"
    }
    return "· \(visibleCount) of \(totalCount)"
  }

  @ViewBuilder private var showAllButton: some View {
    if !isCollapsed, totalCount > visibleCount || isExpanded {
      Button(action: onToggleExpand) {
        Text(isExpanded ? "Show less" : "Show all (\(totalCount))")
          .font(.caption2)
          .foregroundStyle(Color.accentColor)
      }
      .harnessPlainButtonStyle()
      .accessibilityHint(
        isExpanded
          ? "Collapse this section back to the default cap"
          : "Show every match for this section"
      )
    }
  }

  private var accessibilityLabelText: String {
    let suffix = totalCount == 1 ? "" : "s"
    return "\(title) section, \(totalCount) result\(suffix)"
  }
}

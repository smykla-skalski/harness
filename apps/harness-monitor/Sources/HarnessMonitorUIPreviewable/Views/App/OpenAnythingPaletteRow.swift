import HarnessMonitorKit
import SwiftUI

/// Per-result row of the Open Anything palette. Extracted from the view file
/// so the surrounding palette layout stays scannable and so the row can host
/// its own hover, drag, and context-menu state without bloating the parent.
struct OpenAnythingPaletteRow: View {
  let hit: OpenAnythingHit
  let isSelected: Bool
  let isPinned: Bool
  let chordHint: String?
  let onActivate: () -> Void
  let onHover: () -> Void
  let onTogglePin: () -> Void
  let onCopyID: () -> Void

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    Button(action: onActivate) {
      HStack(spacing: OpenAnythingPaletteConstants.rowSpacing) {
        icon
        VStack(alignment: .leading, spacing: 2) {
          title
          subtitle
        }
        Spacer(minLength: 12)
        trailing
        chordChip
        pinIndicator
      }
      .padding(.horizontal, OpenAnythingPaletteConstants.rowHorizontalPadding)
      .padding(.vertical, OpenAnythingPaletteConstants.rowVerticalPadding)
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .background(rowBackground)
    .foregroundStyle(.primary)
    .onHover { hovering in
      isHovered = hovering
      if hovering {
        onHover()
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingRow(hit.id))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityHint("Press return to open")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .overlay(alignment: .trailing) {
      if isSelected {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.openAnythingSelectedState,
          text: hit.id
        )
      }
    }
    .contextMenu {
      Button(isPinned ? "Unpin" : "Pin to top", action: onTogglePin)
      Button("Copy ID", action: onCopyID)
    }
    // Audit #93: rows are draggable as their visible title so users can drag
    // a session or review name into another app (text editor, Slack
    // composer, etc.). The dragged payload is the title string - drop
    // targets that take text see a useful identifier without needing a
    // structured URL scheme.
    .draggable(hit.record.title)
  }

  private var icon: some View {
    Image(systemName: hit.record.systemImage)
      .symbolRenderingMode(.hierarchical)
      .frame(width: OpenAnythingPaletteConstants.rowIconColumnWidth)
      .foregroundStyle(isSelected ? Color.accentColor : HarnessMonitorTheme.secondaryInk)
  }

  private var title: some View {
    SearchHighlightedText(text: hit.record.title, highlights: hit.highlights.title)
      .lineLimit(1)
  }

  @ViewBuilder private var subtitle: some View {
    if let subtitle = hit.record.subtitle, !subtitle.isEmpty {
      SearchHighlightedText(text: subtitle, highlights: hit.highlights.subtitle)
        .font(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
    }
  }

  @ViewBuilder private var trailing: some View {
    if let value = hit.record.trailing, !value.isEmpty {
      SearchHighlightedText(text: value, highlights: hit.highlights.trailing)
        .font(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
    }
  }

  @ViewBuilder private var chordChip: some View {
    if let chord = chordHint {
      Text(chord)
        .font(.caption.monospaced())
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.secondary.opacity(0.12))
        )
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder private var pinIndicator: some View {
    if isPinned {
      Image(systemName: "pin.fill")
        .font(.caption2)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        .accessibilityHidden(true)
    }
  }

  private var rowBackground: some View {
    let baseOpacity: Double =
      isSelected
      ? OpenAnythingPaletteConstants.rowSelectedFillOpacity
      : (isHovered ? OpenAnythingPaletteConstants.rowHoverFillOpacity : 0)
    // Full-width, square-edged tint - matches Spotlight / Raycast where the
    // selection bar spans the entire row width with no inset and no corner
    // rounding.
    return Rectangle()
      .fill(Color.accentColor.opacity(baseOpacity))
  }

  private var accessibilityLabelText: String {
    var parts = [hit.record.title]
    if let subtitle = hit.record.subtitle, !subtitle.isEmpty {
      parts.append(subtitle)
    }
    if let trailing = hit.record.trailing, !trailing.isEmpty {
      parts.append(trailing)
    }
    parts.append(hit.domain.label)
    if isPinned {
      parts.append("Pinned")
    }
    return parts.joined(separator: ", ")
  }
}

import HarnessMonitorKit
import SwiftUI

// Section header for a node kind, e.g. SOURCE / CONDITION. Quiet uppercased
// source-list style matching the rest of the app's group labels rather than a
// loud near-white heading.
struct PolicyCanvasLibraryKindHeader: View {
  let kind: PolicyCanvasNodeKind

  var body: some View {
    Text(kind.title.uppercased())
      .scaledFont(.caption2.weight(.semibold))
      .tracking(0.5)
      .foregroundStyle(PolicyCanvasVisualStyle.primaryText.opacity(0.42))
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

// Sub-group label within a kind (Content / Safety under Condition). Styled
// identically to the kind header so every section label reads as one
// consistent treatment; the sub-grouping is conveyed by its position under
// the kind, not a different color, weight, or indent.
struct PolicyCanvasLibrarySubsectionHeader: View {
  let section: PolicyCanvasAutomationPaletteSection

  var body: some View {
    Text(section.title.uppercased())
      .scaledFont(.caption2.weight(.semibold))
      .tracking(0.5)
      .foregroundStyle(PolicyCanvasVisualStyle.primaryText.opacity(0.42))
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

// The generic node for a kind ("Event source", "Policy rule", ...). Renders as
// a palette row and creates a base node on click or drag.
struct PolicyCanvasBaseComponentRow: View {
  let viewModel: PolicyCanvasViewModel
  let kind: PolicyCanvasNodeKind
  let metrics: PolicyCanvasToolRailMetrics
  @State private var isHovering = false

  var body: some View {
    Button {
      viewModel.createNode(kind: kind, at: viewModel.nextPaletteDropCenter())
    } label: {
      PolicyCanvasComponentRowContent(
        title: kind.libraryTitle,
        subtitle: kind.librarySubtitle,
        symbolName: kind.symbolName,
        accent: kind.accentColor,
        isHovering: isHovering,
        metrics: metrics
      )
    }
    .harnessPlainButtonStyle()
    .draggable(viewModel.palettePayload(for: kind)) {
      PolicyCanvasPaletteDragChip(kind: kind, metrics: metrics)
    }
    .onHover { isHovering = $0 }
    .help("Add \(kind.title)")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPaletteItem(kind.rawValue))
  }
}

// A preset automation component (clipboard monitor, OCR images, ...). Same row
// shape as the base node so the palette reads as one consistent list.
struct PolicyCanvasAutomationVariantRow: View {
  let viewModel: PolicyCanvasViewModel
  let item: PolicyCanvasAutomationPaletteItem
  let metrics: PolicyCanvasToolRailMetrics
  @State private var isHovering = false

  var body: some View {
    Button {
      viewModel.createAutomationNode(item: item, at: viewModel.nextPaletteDropCenter())
    } label: {
      PolicyCanvasComponentRowContent(
        title: item.libraryTitle,
        subtitle: item.librarySubtitle,
        symbolName: item.symbolName,
        accent: item.nodeKind.accentColor,
        isHovering: isHovering,
        metrics: metrics
      )
    }
    .harnessPlainButtonStyle()
    .draggable(viewModel.palettePayload(for: item)) {
      PolicyCanvasAutomationVariantDragChip(item: item, metrics: metrics)
    }
    .onHover { isHovering = $0 }
    .help(item.subtitle)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasPaletteItem("automation.\(item.rawValue)")
    )
  }
}

// Shared row body: an accent icon chip (mirroring `PolicyCanvasNodeCard`) and a
// stacked title over subtitle, on a rounded hover pill.
private struct PolicyCanvasComponentRowContent: View {
  let title: String
  let subtitle: String
  let symbolName: String
  let accent: Color
  let isHovering: Bool
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    HStack(alignment: .center, spacing: 9) {
      Image(systemName: symbolName)
        .scaledFont(.system(size: glyphSize, weight: .medium))
        .foregroundStyle(accent.opacity(isHovering ? 0.96 : 0.82))
        .frame(width: chipSize, height: chipSize)
        .background(
          accent.opacity(isHovering ? 0.18 : 0.12),
          in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .scaledFont(.callout.weight(.medium))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)

        Text(subtitle)
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(isHovering ? PolicyCanvasVisualStyle.controlHoverSurface : .clear)
    )
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private var chipSize: CGFloat {
    max(24, (24 * metrics.scale).rounded())
  }

  private var glyphSize: CGFloat {
    max(12, (13 * metrics.scale).rounded())
  }
}

// Drag preview for automation presets. Already a mini node card, kept in sync
// with `PolicyCanvasNodeCard`'s chip + elevated-surface language.
private struct PolicyCanvasAutomationVariantDragChip: View {
  let item: PolicyCanvasAutomationPaletteItem
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: item.symbolName)
        .scaledFont(.system(size: max(14, metrics.iconSize - 1), weight: .semibold))
        .foregroundStyle(item.nodeKind.accentColor.opacity(0.84))
        .frame(width: 22, height: 22)
        .background(
          item.nodeKind.accentColor.opacity(0.10),
          in: RoundedRectangle(cornerRadius: 5)
        )

      Text(item.libraryTitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        .lineLimit(1)
    }
    .padding(.horizontal, metrics.chipHorizontalPadding)
    .padding(.vertical, metrics.chipVerticalPadding)
    .background(
      PolicyCanvasVisualStyle.elevatedSurface.opacity(0.96),
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
        .stroke(item.nodeKind.accentColor.opacity(0.26), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
  }
}

import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

// Section header for a node kind, e.g. SOURCE / CONDITION. Quiet uppercased
// source-list style matching the rest of the app's group labels rather than a
// loud near-white heading.
struct PolicyCanvasLibraryKindHeader: View {
  let title: String

  var body: some View {
    Text(title.uppercased())
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
    PolicyCanvasComponentRowContent(
      title: kind.libraryTitle,
      subtitle: kind.librarySubtitle,
      symbolName: kind.symbolName,
      accent: kind.accentColor,
      isHovering: isHovering,
      metrics: metrics
    )
    .overlay {
      PolicyCanvasPaletteDragSource(
        payload: viewModel.palettePayload(for: kind),
        previewTitle: kind.libraryTitle,
        previewSymbolName: kind.symbolName,
        activate: addNode,
        setHovering: { isHovering = $0 }
      )
    }
    .onHover { isHovering = $0 }
    .help("Add \(kind.title)")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.libraryTitle)
    .accessibilityValue(kind.librarySubtitle)
    .accessibilityHint("Click to add, or drag to place on the canvas")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      addNode()
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPaletteItem(kind.rawValue))
  }

  private func addNode() {
    viewModel.createNode(kind: kind, at: viewModel.nextPaletteDropCenter())
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
    PolicyCanvasComponentRowContent(
      title: item.libraryTitle,
      subtitle: item.librarySubtitle,
      symbolName: item.symbolName,
      accent: item.nodeKind.accentColor,
      isHovering: isHovering,
      metrics: metrics
    )
    .overlay {
      PolicyCanvasPaletteDragSource(
        payload: viewModel.palettePayload(for: item),
        previewTitle: item.libraryTitle,
        previewSymbolName: item.symbolName,
        activate: addNode,
        setHovering: { isHovering = $0 }
      )
    }
    .onHover { isHovering = $0 }
    .help(item.subtitle)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.libraryTitle)
    .accessibilityValue(item.librarySubtitle)
    .accessibilityHint("Click to add, or drag to place on the canvas")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      addNode()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasPaletteItem("automation.\(item.rawValue)")
    )
  }

  private func addNode() {
    viewModel.createAutomationNode(item: item, at: viewModel.nextPaletteDropCenter())
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
    metrics.rowIconSize
  }

  private var glyphSize: CGFloat {
    max(12, (13 * metrics.scale).rounded())
  }
}

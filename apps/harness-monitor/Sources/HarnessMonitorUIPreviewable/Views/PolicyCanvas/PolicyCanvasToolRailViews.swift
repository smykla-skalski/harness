import HarnessMonitorKit
import SwiftUI

/// Left-side tool rail with draggable palette buttons + the bottom-leading
/// zoom controls. Pulled out of `PolicyCanvasChromeViews.swift` so the
/// chrome file stays under the 420-line cap; the views themselves are
/// unchanged.
struct PolicyCanvasToolRail: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    let metrics = PolicyCanvasToolRailMetrics(fontScale: fontScale)
    VStack(spacing: metrics.itemSpacing) {
      PolicyCanvasAutomationPaletteMenu(viewModel: viewModel, metrics: metrics)

      Divider()
        .overlay(PolicyCanvasVisualStyle.separator)

      ForEach(PolicyCanvasNodeKind.allCases) { kind in
        PolicyCanvasPaletteButton(viewModel: viewModel, kind: kind, metrics: metrics)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, metrics.verticalPadding)
    .padding(.horizontal, metrics.horizontalPadding)
    .frame(width: metrics.railWidth)
    .background(PolicyCanvasVisualStyle.railBackground)
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(width: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolRail)
  }
}

struct PolicyCanvasToolRailMetrics: Equatable {
  let scale: CGFloat
  let railWidth: CGFloat
  let itemSpacing: CGFloat
  let verticalPadding: CGFloat
  let horizontalPadding: CGFloat
  let buttonWidth: CGFloat
  let buttonHeight: CGFloat
  let iconSize: CGFloat
  let chipHorizontalPadding: CGFloat
  let chipVerticalPadding: CGFloat

  init(fontScale: CGFloat) {
    scale = min(SessionWindowFontScale.metricsScale(for: fontScale), 1.45)
    railWidth = (108 * scale).rounded(.up)
    itemSpacing = (7 * scale).rounded(.up)
    verticalPadding = (12 * scale).rounded(.up)
    horizontalPadding = (8 * scale).rounded(.up)
    buttonWidth = (92 * scale).rounded(.up)
    buttonHeight = (34 * scale).rounded(.up)
    iconSize = (13 * scale).rounded(.up)
    chipHorizontalPadding = (10 * scale).rounded(.up)
    chipVerticalPadding = (7 * scale).rounded(.up)
  }
}

private struct PolicyCanvasPaletteButton: View {
  let viewModel: PolicyCanvasViewModel
  let kind: PolicyCanvasNodeKind
  let metrics: PolicyCanvasToolRailMetrics

  @State private var isHovering = false

  var body: some View {
    Button {
      viewModel.createNode(kind: kind, at: viewModel.nextPaletteDropCenter())
    } label: {
      HStack(spacing: 7) {
        Image(systemName: kind.symbolName)
          .scaledFont(.system(size: metrics.iconSize, weight: .semibold))
          .foregroundStyle(kind.accentColor.opacity(isHovering ? 0.95 : 0.78))
          .frame(width: 22, height: 22)
          .background(
            kind.accentColor.opacity(isHovering ? 0.14 : 0.08),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )

        Text(kind.title)
          .scaledFont(.caption2.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
          .lineLimit(1)
          .minimumScaleFactor(0.8)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 7)
      .frame(width: metrics.buttonWidth, height: metrics.buttonHeight)
      .background(
        isHovering ? PolicyCanvasVisualStyle.controlHoverSurface : PolicyCanvasVisualStyle.surface,
        in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
          .stroke(
            isHovering ? kind.accentColor.opacity(0.38) : PolicyCanvasVisualStyle.subtleBorder,
            lineWidth: 1
          )
      }
      .animation(.easeOut(duration: 0.12), value: isHovering)
    }
    .harnessPlainButtonStyle()
    .draggable(viewModel.palettePayload(for: kind)) {
      PolicyCanvasPaletteDragChip(kind: kind, metrics: metrics)
    }
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        NSCursor.openHand.push()
      } else {
        NSCursor.pop()
      }
    }
    .help("Drag onto the canvas, or click to drop near the center")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPaletteItem(kind.rawValue))
  }
}

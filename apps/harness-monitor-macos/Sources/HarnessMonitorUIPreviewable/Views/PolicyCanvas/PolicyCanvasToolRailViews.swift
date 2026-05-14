import HarnessMonitorKit
import SwiftUI

/// Left-side tool rail with draggable palette buttons + the bottom-leading
/// zoom controls. Pulled out of `PolicyCanvasChromeViews.swift` so the
/// chrome file stays under the 420-line cap; the views themselves are
/// unchanged.
struct PolicyCanvasToolRail: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.fontScale) private var fontScale

  var body: some View {
    let metrics = PolicyCanvasToolRailMetrics(fontScale: fontScale)
    VStack(spacing: metrics.itemSpacing) {
      ForEach(PolicyCanvasNodeKind.allCases) { kind in
        PolicyCanvasPaletteButton(viewModel: viewModel, kind: kind, metrics: metrics)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, metrics.verticalPadding)
    .padding(.horizontal, metrics.horizontalPadding)
    .frame(width: metrics.railWidth)
    .background(Color(red: 0.07, green: 0.08, blue: 0.11))
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(.white.opacity(0.07))
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
    railWidth = (84 * scale).rounded(.up)
    itemSpacing = (10 * scale).rounded(.up)
    verticalPadding = (14 * scale).rounded(.up)
    horizontalPadding = (8 * scale).rounded(.up)
    buttonWidth = (64 * scale).rounded(.up)
    buttonHeight = (52 * scale).rounded(.up)
    iconSize = (15 * scale).rounded(.up)
    chipHorizontalPadding = (10 * scale).rounded(.up)
    chipVerticalPadding = (7 * scale).rounded(.up)
  }
}

private struct PolicyCanvasPaletteButton: View {
  let viewModel: PolicyCanvasViewModel
  let kind: PolicyCanvasNodeKind
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    Button {
      viewModel.createNode(kind: kind, at: viewModel.nextPaletteDropCenter())
    } label: {
      VStack(spacing: 5) {
        Image(systemName: kind.symbolName)
          .scaledFont(.system(size: metrics.iconSize, weight: .semibold))
        Text(kind.title)
          .scaledFont(.caption2.weight(.semibold))
          .lineLimit(1)
      }
      .foregroundStyle(kind.accentColor)
      .frame(width: metrics.buttonWidth, height: metrics.buttonHeight)
      .background(kind.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(kind.accentColor.opacity(0.38), lineWidth: 1)
      }
    }
    .harnessPlainButtonStyle()
    .draggable(viewModel.palettePayload(for: kind)) {
      PolicyCanvasPaletteDragChip(kind: kind, metrics: metrics)
    }
    .help("Drag onto the canvas, or click to drop near the center.")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasPaletteItem(kind.rawValue))
  }
}

/// Ghost chip rendered under the cursor while the user drags a palette item.
/// Mirrors the kind's accent color and icon so the user has a positive system
/// image of what the drop will create. Vanishes automatically when the drag
/// ends (handled by `.draggable(preview:)`).
private struct PolicyCanvasPaletteDragChip: View {
  let kind: PolicyCanvasNodeKind
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: kind.symbolName)
        .scaledFont(.system(size: max(14, metrics.iconSize - 1), weight: .semibold))
        .foregroundStyle(kind.accentColor)
        .frame(width: 22, height: 22)
        .background(kind.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))

      Text(kind.title)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, metrics.chipHorizontalPadding)
    .padding(.vertical, metrics.chipVerticalPadding)
    .background(Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.94), in: Capsule())
    .overlay {
      Capsule()
        .stroke(kind.accentColor.opacity(0.55), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
  }
}

struct PolicyCanvasZoomControls: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    HStack(spacing: 6) {
      Button {
        viewModel.zoomOut()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .keyboardShortcut("-", modifiers: [.command])
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomOutButton)

      Text("\(Int((viewModel.zoom * 100).rounded()))%")
        .scaledFont(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white.opacity(0.86))
        .frame(width: 46)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomValue)

      Button {
        viewModel.zoomIn()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .keyboardShortcut("+", modifiers: [.command])
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomInButton)

      Button {
        viewModel.resetZoom()
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .keyboardShortcut("0", modifiers: [.command])
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomResetButton)
    }
    .harnessActionButtonStyle(variant: .borderless)
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomControls)
  }
}

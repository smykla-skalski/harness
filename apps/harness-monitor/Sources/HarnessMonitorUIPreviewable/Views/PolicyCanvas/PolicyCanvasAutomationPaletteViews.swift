import SwiftUI

struct PolicyCanvasAutomationPaletteMenu: View {
  let viewModel: PolicyCanvasViewModel
  let metrics: PolicyCanvasToolRailMetrics

  @State private var isHovering = false

  var body: some View {
    Menu {
      ForEach(PolicyCanvasAutomationPaletteSection.allCases) { section in
        Section(section.title) {
          ForEach(PolicyCanvasAutomationPaletteItem.items(in: section)) { item in
            Button {
              viewModel.createAutomationNode(
                item: item,
                at: viewModel.nextPaletteDropCenter()
              )
            } label: {
              Label(item.title, systemImage: item.symbolName)
            }
            .help(item.subtitle)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.policyCanvasPaletteItem("automation.\(item.rawValue)")
            )
          }
        }
      }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "wand.and.stars")
          .scaledFont(.system(size: metrics.iconSize, weight: .semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.activeTint.opacity(isHovering ? 0.95 : 0.78))
          .frame(width: 22, height: 22)
          .background(
            PolicyCanvasVisualStyle.activeTint.opacity(isHovering ? 0.14 : 0.08),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
        Text("Auto")
          .scaledFont(.caption2.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
          .lineLimit(1)
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
            isHovering
              ? PolicyCanvasVisualStyle.activeTint.opacity(0.38)
              : PolicyCanvasVisualStyle.subtleBorder,
            lineWidth: 1
          )
      }
    }
    .menuStyle(.button)
    .harnessPlainButtonStyle()
    .onHover { hovering in
      isHovering = hovering
    }
    .help("Add clipboard, paste, screenshot, OCR, privacy, action, and result policy components")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasPaletteItem("automation-menu")
    )
  }
}

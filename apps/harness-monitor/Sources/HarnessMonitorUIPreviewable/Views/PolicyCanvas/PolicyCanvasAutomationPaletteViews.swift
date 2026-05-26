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
      VStack(spacing: 5) {
        Image(systemName: "wand.and.stars")
          .scaledFont(.system(size: metrics.iconSize, weight: .semibold))
        Text("Auto")
          .scaledFont(.caption2.weight(.semibold))
          .lineLimit(1)
      }
      .foregroundStyle(Color.cyan)
      .frame(width: metrics.buttonWidth, height: metrics.buttonHeight)
      .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.cyan.opacity(isHovering ? 0.82 : 0.42), lineWidth: isHovering ? 1.4 : 1)
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

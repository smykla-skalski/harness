import HarnessMonitorKit
import SwiftUI

struct PolicyCanvasComponentLibraryPane: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    let metrics = PolicyCanvasToolRailMetrics(fontScale: fontScale)
    VStack(alignment: .leading, spacing: 0) {
      header

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(PolicyCanvasNodeKind.allCases) { kind in
            PolicyCanvasComponentGroupView(
              viewModel: viewModel,
              kind: kind,
              sections: Self.variantSections(for: kind),
              metrics: metrics
            )
          }
        }
        .padding(.vertical, 6)
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolRail)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(PolicyCanvasVisualStyle.railBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasComponentLibrary)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Policy library")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)

      Text("Components and variants")
        .scaledFont(.caption2)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
  }

  private static func variantSections(
    for kind: PolicyCanvasNodeKind
  ) -> [PolicyCanvasAutomationPaletteSection] {
    switch kind {
    case .source:
      [.sources]
    case .condition:
      [.content, .safety]
    case .review:
      []
    case .transform:
      [.results]
    case .decision:
      [.actions]
    }
  }
}

struct PolicyCanvasToolRail: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    PolicyCanvasComponentLibraryPane(viewModel: viewModel)
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
    itemSpacing = (4 * scale).rounded(.up)
    verticalPadding = (6 * scale).rounded(.up)
    horizontalPadding = (10 * scale).rounded(.up)
    buttonWidth = (92 * scale).rounded(.up)
    buttonHeight = (30 * scale).rounded(.up)
    iconSize = (12 * scale).rounded(.up)
    chipHorizontalPadding = (10 * scale).rounded(.up)
    chipVerticalPadding = (7 * scale).rounded(.up)
  }
}

private struct PolicyCanvasComponentGroupView: View {
  let viewModel: PolicyCanvasViewModel
  let kind: PolicyCanvasNodeKind
  let sections: [PolicyCanvasAutomationPaletteSection]
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PolicyCanvasBaseComponentRow(viewModel: viewModel, kind: kind, metrics: metrics)

      ForEach(sections) { section in
        PolicyCanvasVariantSectionView(
          viewModel: viewModel,
          section: section,
          metrics: metrics
        )
      }
    }
    .padding(.top, 4)
  }
}

private struct PolicyCanvasVariantSectionView: View {
  let viewModel: PolicyCanvasViewModel
  let section: PolicyCanvasAutomationPaletteSection
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(section.title)
        .scaledFont(.caption2.weight(.medium))
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .padding(.leading, 42)

      ForEach(PolicyCanvasAutomationPaletteItem.items(in: section)) { item in
        PolicyCanvasAutomationVariantRow(
          viewModel: viewModel,
          item: item,
          metrics: metrics
        )
      }
    }
  }
}

private struct PolicyCanvasBaseComponentRow: View {
  let viewModel: PolicyCanvasViewModel
  let kind: PolicyCanvasNodeKind
  let metrics: PolicyCanvasToolRailMetrics
  @State private var isHovering = false

  var body: some View {
    Button {
      viewModel.createNode(kind: kind, at: viewModel.nextPaletteDropCenter())
    } label: {
      PolicyCanvasComponentRowContent(
        title: kind.title,
        subtitle: kind.subtitle,
        symbolName: kind.symbolName,
        tint: kind.accentColor,
        isHovering: isHovering,
        rowKind: .base,
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

private struct PolicyCanvasAutomationVariantRow: View {
  let viewModel: PolicyCanvasViewModel
  let item: PolicyCanvasAutomationPaletteItem
  let metrics: PolicyCanvasToolRailMetrics
  @State private var isHovering = false

  var body: some View {
    Button {
      viewModel.createAutomationNode(item: item, at: viewModel.nextPaletteDropCenter())
    } label: {
      PolicyCanvasComponentRowContent(
        title: item.title,
        subtitle: item.subtitle,
        symbolName: item.symbolName,
        tint: item.nodeKind.accentColor,
        isHovering: isHovering,
        rowKind: .variant,
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

private struct PolicyCanvasComponentRowContent: View {
  let title: String
  let subtitle: String
  let symbolName: String
  let tint: Color
  let isHovering: Bool
  let rowKind: PolicyCanvasComponentRowKind
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .scaledFont(.system(size: iconSize, weight: iconWeight))
        .foregroundStyle(iconColor)
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .scaledFont(titleFont)
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)
          .minimumScaleFactor(0.78)

        Text(subtitle)
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
      }

      Spacer(minLength: 0)
    }
    .padding(.leading, rowKind.leadingPadding)
    .padding(.trailing, 10)
    .padding(.vertical, rowKind.verticalPadding)
    .frame(minHeight: rowKind.minHeight, alignment: .center)
    .contentShape(Rectangle())
    .background(alignment: .center) {
      if isHovering {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(PolicyCanvasVisualStyle.controlHoverSurface)
          .padding(.horizontal, 6)
      }
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .padding(.leading, rowKind.separatorLeadingPadding)
        .frame(height: 1)
    }
  }

  private var titleFont: Font {
    switch rowKind {
    case .base:
      .caption.weight(.semibold)
    case .variant:
      .caption.weight(.medium)
    }
  }

  private var iconSize: CGFloat {
    switch rowKind {
    case .base:
      max(12, metrics.iconSize)
    case .variant:
      max(11, metrics.iconSize - 1)
    }
  }

  private var iconWeight: Font.Weight {
    switch rowKind {
    case .base:
      .semibold
    case .variant:
      .medium
    }
  }

  private var iconColor: Color {
    switch rowKind {
    case .base:
      tint.opacity(isHovering ? 0.74 : 0.58)
    case .variant:
      PolicyCanvasVisualStyle.secondaryText.opacity(isHovering ? 0.76 : 0.56)
    }
  }
}

private enum PolicyCanvasComponentRowKind {
  case base
  case variant

  var leadingPadding: CGFloat {
    switch self {
    case .base:
      12
    case .variant:
      42
    }
  }

  var separatorLeadingPadding: CGFloat {
    switch self {
    case .base:
      12
    case .variant:
      42
    }
  }

  var verticalPadding: CGFloat {
    switch self {
    case .base:
      6
    case .variant:
      4
    }
  }

  var minHeight: CGFloat {
    switch self {
    case .base:
      38
    case .variant:
      32
    }
  }
}

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

      Text(item.title)
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

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

      List(Self.libraryRows) { row in
        rowView(row, metrics: metrics)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 24)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolRail)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(PolicyCanvasVisualStyle.railBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasComponentLibrary)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Policy library")
        .scaledFont(.caption2.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        .lineLimit(1)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
  }

  @ViewBuilder
  private func rowView(
    _ row: PolicyCanvasComponentLibraryRow,
    metrics: PolicyCanvasToolRailMetrics
  ) -> some View {
    switch row {
    case .kindHeader(let kind):
      PolicyCanvasLibraryKindHeader(kind: kind)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 9, leading: 12, bottom: 2, trailing: 10))
        .listRowBackground(Color.clear)
    case .subsection(let section):
      PolicyCanvasLibrarySubsectionHeader(section: section)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 36, bottom: 1, trailing: 10))
        .listRowBackground(Color.clear)
    case .base(let kind):
      PolicyCanvasBaseComponentRow(viewModel: viewModel, kind: kind, metrics: metrics)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10))
        .listRowBackground(Color.clear)
    case .variant(let item):
      PolicyCanvasAutomationVariantRow(viewModel: viewModel, item: item, metrics: metrics)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10))
        .listRowBackground(Color.clear)
    }
  }

  private static var libraryRows: [PolicyCanvasComponentLibraryRow] {
    var rows: [PolicyCanvasComponentLibraryRow] = []
    for kind in PolicyCanvasNodeKind.allCases {
      rows.append(.kindHeader(kind))
      rows.append(.base(kind))

      let sections = variantSections(for: kind)
      for section in sections {
        if sections.count > 1 {
          rows.append(.subsection(section))
        }
        rows.append(
          contentsOf: PolicyCanvasAutomationPaletteItem.items(in: section).map {
            .variant($0)
          })
      }
    }
    return rows
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
    itemSpacing = (3 * scale).rounded(.up)
    verticalPadding = (4 * scale).rounded(.up)
    horizontalPadding = (10 * scale).rounded(.up)
    buttonWidth = (92 * scale).rounded(.up)
    buttonHeight = (24 * scale).rounded(.up)
    iconSize = (11 * scale).rounded(.up)
    chipHorizontalPadding = (10 * scale).rounded(.up)
    chipVerticalPadding = (7 * scale).rounded(.up)
  }
}

private enum PolicyCanvasComponentLibraryRow: Identifiable {
  case kindHeader(PolicyCanvasNodeKind)
  case subsection(PolicyCanvasAutomationPaletteSection)
  case base(PolicyCanvasNodeKind)
  case variant(PolicyCanvasAutomationPaletteItem)

  var id: String {
    switch self {
    case .kindHeader(let kind):
      "kind-header.\(kind.rawValue)"
    case .subsection(let section):
      "subsection.\(section.rawValue)"
    case .base(let kind):
      "base.\(kind.rawValue)"
    case .variant(let item):
      "variant.\(item.rawValue)"
    }
  }
}

private struct PolicyCanvasLibraryKindHeader: View {
  let kind: PolicyCanvasNodeKind

  var body: some View {
    Text(kind.title)
      .scaledFont(.caption2.weight(.semibold))
      .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isHeader)
  }
}

private struct PolicyCanvasLibrarySubsectionHeader: View {
  let section: PolicyCanvasAutomationPaletteSection

  var body: some View {
    Text(section.title)
      .scaledFont(.caption2)
      .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
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
        title: kind.libraryTitle,
        subtitle: kind.librarySubtitle,
        symbolName: kind.symbolName,
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
        title: item.libraryTitle,
        subtitle: item.librarySubtitle,
        symbolName: item.symbolName,
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
  let isHovering: Bool
  let rowKind: PolicyCanvasComponentRowKind
  let metrics: PolicyCanvasToolRailMetrics

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Image(systemName: symbolName)
        .scaledFont(.system(size: iconSize, weight: iconWeight))
        .foregroundStyle(iconColor)
        .frame(width: 16, alignment: .center)

      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title)
          .scaledFont(titleFont)
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)
          .layoutPriority(1)

        Text(subtitle)
          .scaledFont(.caption2)
          .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 0)
    .frame(height: rowKind.rowHeight, alignment: .center)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(isHovering ? PolicyCanvasVisualStyle.controlHoverSurface.opacity(0.55) : .clear)
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
      .medium
    case .variant:
      .regular
    }
  }

  private var iconColor: Color {
    PolicyCanvasVisualStyle.secondaryText.opacity(isHovering ? 0.74 : 0.56)
  }
}

private enum PolicyCanvasComponentRowKind {
  case base
  case variant

  var rowHeight: CGFloat {
    switch self {
    case .base:
      25
    case .variant:
      24
    }
  }
}

extension PolicyCanvasNodeKind {
  fileprivate var libraryTitle: String {
    switch self {
    case .source:
      "Event source"
    case .condition:
      "Policy rule"
    case .review:
      "Manual review"
    case .transform:
      "Transform step"
    case .decision:
      "Decision outcome"
    }
  }

  fileprivate var librarySubtitle: String {
    switch self {
    case .source:
      "Generic intake"
    case .condition:
      "Generic condition"
    case .review:
      "Human checkpoint"
    case .transform:
      "Context mapping"
    case .decision:
      "Route result"
    }
  }
}

extension PolicyCanvasAutomationPaletteItem {
  fileprivate var libraryTitle: String {
    switch self {
    case .dragDropOCR:
      "Dropped images"
    case .filePickerOCR:
      "Selected files"
    case .dedupeFingerprint:
      "Deduplication"
    case .sourceSpecificCleanup:
      "Text cleanup"
    case .persistResult:
      "Persist OCR"
    default:
      title
    }
  }

  fileprivate var librarySubtitle: String {
    switch self {
    case .clipboardMonitor:
      "Pasteboard polling"
    case .focusedPaste:
      "Focused paste events"
    case .dragDropOCR:
      "OCR on dropped images"
    case .filePickerOCR:
      "OCR on selected images"
    case .screenshotFolder:
      "Screenshot files"
    case .contentImages:
      "Screenshots and images"
    case .contentText:
      "Copied text"
    case .contentFiles:
      "File URLs"
    case .contentURLs:
      "Copied links"
    case .pasteboardPrivacy:
      "Pasteboard privacy"
    case .skipSensitiveMarkers:
      "Transient content"
    case .sourceApplicationFilter:
      "Source app allowlist"
    case .dedupeFingerprint:
      "Duplicate scans"
    case .ocrImages:
      "OCR recognition"
    case .rememberRecentScans:
      "Recent scan storage"
    case .showFeedback:
      "Visual feedback"
    case .openDebugging:
      "Debugging route"
    case .recordMetadata:
      "Source metadata"
    case .sourceSpecificCleanup:
      "Recognized text"
    case .persistResult:
      "OCR text persistence"
    case .auditEvent:
      "Policy event log"
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

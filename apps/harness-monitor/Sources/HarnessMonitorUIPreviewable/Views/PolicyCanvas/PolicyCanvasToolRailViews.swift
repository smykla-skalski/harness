import AppKit
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasComponentLibraryPane: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    let metrics = PolicyCanvasToolRailMetrics(fontScale: fontScale)
    VStack(alignment: .leading, spacing: 0) {
      List(Self.libraryRows) { row in
        rowView(row, metrics: metrics)
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .environment(\.defaultMinListRowHeight, 1)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolRail)
    }
    // Native `List` does not report a useful horizontal intrinsic size inside
    // this two-pane HStack, so the pane owns a measured content width instead.
    .frame(
      width: Self.libraryPaneWidth(metrics: metrics),
      alignment: .topLeading
    )
    .frame(
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .background(PolicyCanvasVisualStyle.dashboardHostBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasComponentLibrary)
  }

  @ViewBuilder
  private func rowView(
    _ row: PolicyCanvasComponentLibraryRow,
    metrics: PolicyCanvasToolRailMetrics
  ) -> some View {
    // The first kind header sits right under the titled pane header, which
    // already provides space above it, so it takes a smaller top inset to keep
    // the gap above every section header uniform.
    let isFirstRow = Self.libraryRows.first.map { $0.id == row.id } ?? false
    switch row {
    case .header(_, let title):
      PolicyCanvasLibraryKindHeader(title: title)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: isFirstRow ? 10 : 18, leading: 16, bottom: 6, trailing: 10))
        .listRowBackground(Color.clear)
    case .base(let kind):
      PolicyCanvasBaseComponentRow(viewModel: viewModel, kind: kind, metrics: metrics)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    case .variant(let item):
      PolicyCanvasAutomationVariantRow(viewModel: viewModel, item: item, metrics: metrics)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    }
  }

  // Computed once: the palette is constant data, so there is no reason to
  // rebuild the row list on every pane body evaluation.
  private static let libraryRows: [PolicyCanvasComponentLibraryRow] = {
    var rows: [PolicyCanvasComponentLibraryRow] = []
    for section in PolicyCanvasNodeLibrarySection.allCases {
      let kinds = PolicyCanvasNodeKind.authoringCases().filter {
        $0.librarySection == section
      }
      guard !kinds.isEmpty else {
        continue
      }
      rows.append(.header(id: "policy.\(section.rawValue)", title: section.title))
      rows.append(contentsOf: kinds.map { .base($0) })
    }
    let automationSections = PolicyCanvasAutomationPaletteSection.allCases.filter {
      !PolicyCanvasAutomationPaletteItem.items(in: $0).isEmpty
    }
    if !automationSections.isEmpty {
      rows.append(.header(id: "automation.root", title: "Automation presets"))
      for section in automationSections {
        rows.append(.header(id: "automation.\(section.rawValue)", title: section.title))
        rows.append(
          contentsOf: PolicyCanvasAutomationPaletteItem.items(in: section).map {
            .variant($0)
          })
      }
    }
    return rows
  }()

  private static let baseTextWidths = PolicyCanvasLibraryPaneTextWidths(rows: libraryRows)

  private static func libraryPaneWidth(metrics: PolicyCanvasToolRailMetrics) -> CGFloat {
    PolicyCanvasLibraryPaneWidth.width(baseTextWidths: baseTextWidths, metrics: metrics)
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
  let rowIconSize: CGFloat
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
    rowIconSize = max(24, (24 * scale).rounded())
    iconSize = (11 * scale).rounded(.up)
    chipHorizontalPadding = (10 * scale).rounded(.up)
    chipVerticalPadding = (7 * scale).rounded(.up)
  }
}

private enum PolicyCanvasComponentLibraryRow: Identifiable {
  case header(id: String, title: String)
  case base(PolicyCanvasNodeKind)
  case variant(PolicyCanvasAutomationPaletteItem)

  var id: String {
    switch self {
    case .header(let id, _):
      id
    case .base(let kind):
      "base.\(kind.rawValue)"
    case .variant(let item):
      "variant.\(item.rawValue)"
    }
  }
}

extension PolicyCanvasComponentLibraryRow {
  var headerTitle: String? {
    switch self {
    case .header(_, let title):
      title
    case .base, .variant:
      nil
    }
  }

  var actionTitle: String? {
    switch self {
    case .base(let kind):
      kind.libraryTitle
    case .variant(let item):
      item.libraryTitle
    case .header:
      nil
    }
  }

  var actionSubtitle: String? {
    switch self {
    case .base(let kind):
      kind.librarySubtitle
    case .variant(let item):
      item.librarySubtitle
    case .header:
      nil
    }
  }
}

private struct PolicyCanvasLibraryPaneTextWidths {
  let header: CGFloat
  let action: CGFloat

  init(rows: [PolicyCanvasComponentLibraryRow]) {
    let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    let subtitleFont = NSFont.systemFont(ofSize: 11)

    header =
      rows.compactMap(\.headerTitle)
      .map { Self.measuredWidth($0.uppercased(), font: headerFont, tracking: 0.5) }
      .max() ?? 0
    let actionTitles = rows.compactMap(\.actionTitle)
      .map { Self.measuredWidth($0, font: titleFont) }
    let actionSubtitles = rows.compactMap(\.actionSubtitle)
      .map { Self.measuredWidth($0, font: subtitleFont) }
    action = max((actionTitles + actionSubtitles).max() ?? 0, 0)
  }

  private static func measuredWidth(
    _ text: String,
    font: NSFont,
    tracking: CGFloat = 0
  ) -> CGFloat {
    let baseWidth = (text as NSString).size(withAttributes: [.font: font]).width
    return baseWidth + max(CGFloat(text.count - 1), 0) * tracking
  }
}

private enum PolicyCanvasLibraryPaneWidth {
  static func width(
    baseTextWidths: PolicyCanvasLibraryPaneTextWidths,
    metrics: PolicyCanvasToolRailMetrics
  ) -> CGFloat {
    let headerWidth = 16 + scaled(baseTextWidths.header, metrics: metrics) + 10
    let actionWidth =
      8 + 8 + metrics.rowIconSize + 9 + scaled(baseTextWidths.action, metrics: metrics) + 8 + 8
    return max(headerWidth, actionWidth).rounded(.up)
  }

  private static func scaled(_ width: CGFloat, metrics: PolicyCanvasToolRailMetrics) -> CGFloat {
    (width * metrics.scale).rounded(.up)
  }
}

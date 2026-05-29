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
        // An eager VStack of buttons, not a List or LazyVStack: the palette is
        // an object library of draggable command buttons, not selectable data,
        // so the rows carry the button role rather than list-row semantics. The
        // pane sizes to its widest row (see `.fixedSize` below), which needs
        // every row measured up front; the rows are constant and cheap.
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Self.libraryRows) { row in
            rowView(row, metrics: metrics)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolRail)
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
    // Hug the content width so the pane takes only the room its actions need
    // and never wastes horizontal space. Row text and chips scale with the
    // font scale, so the resolved width follows the system size automatically.
    .fixedSize(horizontal: true, vertical: false)
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
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.subtleBorder)
        .frame(height: 1)
    }
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
        .padding(EdgeInsets(top: isFirstRow ? 10 : 18, leading: 16, bottom: 6, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    case .base(let kind):
      PolicyCanvasBaseComponentRow(viewModel: viewModel, kind: kind, metrics: metrics)
        .padding(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    case .variant(let item):
      PolicyCanvasAutomationVariantRow(viewModel: viewModel, item: item, metrics: metrics)
        .padding(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // Computed once: the palette is constant data, so there is no reason to
  // rebuild the row list on every pane body evaluation.
  private static let libraryRows: [PolicyCanvasComponentLibraryRow] = {
    var rows: [PolicyCanvasComponentLibraryRow] = []
    for section in PolicyCanvasNodeLibrarySection.allCases {
      let kinds = PolicyCanvasNodeKind.allCases.filter { $0.librarySection == section }
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

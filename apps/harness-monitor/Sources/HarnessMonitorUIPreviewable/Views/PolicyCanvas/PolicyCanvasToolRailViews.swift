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
      .environment(\.defaultMinListRowHeight, 1)
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
    case .kindHeader(let kind):
      PolicyCanvasLibraryKindHeader(kind: kind)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: isFirstRow ? 10 : 18, leading: 16, bottom: 6, trailing: 10))
        .listRowBackground(Color.clear)
    case .subsection(let section):
      PolicyCanvasLibrarySubsectionHeader(section: section)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 6, trailing: 10))
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
  }()

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

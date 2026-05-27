import SwiftUI

extension PolicyCanvasEditForm {
  @ViewBuilder var edgeKindCountsSection: some View {
    if !viewModel.edges.isEmpty {
      let counts = viewModel.edgeCountsByKind
      PolicyCanvasInspectorSection(title: "Edge kinds") {
        ForEach(PolicyCanvasEdgeKind.allCases, id: \.self) { kind in
          PolicyCanvasInspectorRow(
            label: kind.accessibilityWord.capitalized,
            value: "\(counts[kind, default: 0])"
          )
        }
      }
    }
  }
}

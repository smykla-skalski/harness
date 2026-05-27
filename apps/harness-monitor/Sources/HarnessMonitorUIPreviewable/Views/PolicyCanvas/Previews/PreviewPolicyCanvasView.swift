import SwiftUI

#Preview("Policy Canvas") {
  PolicyCanvasView(viewModel: .sample())
    .frame(width: 1180, height: 720)
}

#Preview("Policy Canvas - dense chrome") {
  PolicyCanvasView(viewModel: densePolicyCanvasPreviewViewModel())
    .frame(width: 1480, height: 820)
}

@MainActor
private func densePolicyCanvasPreviewViewModel() -> PolicyCanvasViewModel {
  let viewModel = PolicyCanvasViewModel.sample()
  viewModel.documentDirty = true
  viewModel.hasPendingDocumentUpdate = true
  viewModel.select(nil)
  if let reviewEdgeIndex = viewModel.edges.firstIndex(where: { $0.id == "edge-risk-review" }) {
    viewModel.edges[reviewEdgeIndex].kind = .control
    viewModel.edges[reviewEdgeIndex].condition = "needs human review"
  }
  if let promoteEdgeIndex = viewModel.edges.firstIndex(where: { $0.id == "edge-review-promote" }) {
    viewModel.edges[promoteEdgeIndex].kind = .error
    viewModel.edges[promoteEdgeIndex].condition = "review denied"
  }
  return viewModel
}

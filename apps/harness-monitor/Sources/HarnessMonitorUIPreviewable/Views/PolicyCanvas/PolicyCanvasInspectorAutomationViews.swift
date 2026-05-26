import SwiftUI

extension PolicyCanvasInspector {
  var canvasAutomationPolicySummaryRow: some View {
    PolicyCanvasInspectorRow(
      label: "Automation",
      value: viewModel.automationPolicyCompilation.summaryText
    )
  }

  @ViewBuilder
  func nodeAutomationPolicyPreview(_ node: PolicyCanvasNode) -> some View {
    if let policy = viewModel.automationPolicyCompilation.policy(compiledFrom: node.id) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Canvas Automation")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.86))
        PolicyCanvasInspectorRow(label: "Source", value: policy.eventSource.title)
        PolicyCanvasInspectorRow(label: "Priority", value: "\(policy.priority)")
        PolicyCanvasInspectorRow(
          label: "Content",
          value: policy.match.contentKinds.map(\.title).sorted().joined(separator: ", ")
        )
        PolicyCanvasInspectorRow(
          label: "Actions",
          value: policy.actions.map(\.title).joined(separator: ", ")
        )
      }
    }
  }
}

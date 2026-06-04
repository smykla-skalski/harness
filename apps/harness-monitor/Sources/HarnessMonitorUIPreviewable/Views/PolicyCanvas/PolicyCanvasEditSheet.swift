import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

enum PolicyCanvasEditSheet: Identifiable, Equatable {
  case node(String)
  case group(String)
  case edge(String)
  case selection

  var id: String {
    switch self {
    case .node(let id):
      "node-\(id)"
    case .group(let id):
      "group-\(id)"
    case .edge(let id):
      "edge-\(id)"
    case .selection:
      "selection"
    }
  }

  var primarySelection: PolicyCanvasSelection? {
    switch self {
    case .node(let id):
      .node(id)
    case .group(let id):
      .group(id)
    case .edge(let id):
      .edge(id)
    case .selection:
      nil
    }
  }
}

struct PolicyCanvasEditSheetView: View {
  let viewModel: PolicyCanvasViewModel
  let statusLine: String
  let sheet: PolicyCanvasEditSheet
  let dismiss: @MainActor () -> Void
  @FocusState private var focusedField: PolicyCanvasFocusedField?

  var body: some View {
    VStack(spacing: 0) {
      PolicyCanvasEditForm(
        viewModel: viewModel,
        statusLine: statusLine,
        focusedField: $focusedField
      )

      footer
    }
    .frame(minWidth: 480, idealWidth: 560, maxWidth: 640, minHeight: 420)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEditSheet)
    .harnessMCPElementTrackingEnabled(false)
  }

  private var footer: some View {
    HStack {
      Text("\(sheetLabel) - \(statusLine)")
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .lineLimit(1)

      Spacer(minLength: 16)

      Button("Done") {
        focusedField = nil
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .harnessActionButtonStyle(variant: .bordered)
      .controlSize(.small)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEditDoneButton)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(PolicyCanvasVisualStyle.chromeBackground)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
  }

  private var sheetLabel: String {
    switch sheet {
    case .node:
      "Step"
    case .group:
      "Group"
    case .edge:
      "Connection"
    case .selection:
      "Selection"
    }
  }
}

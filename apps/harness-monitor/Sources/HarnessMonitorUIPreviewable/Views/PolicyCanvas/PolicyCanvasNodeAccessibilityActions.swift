import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

/// P28 per-node accessibility actions modifier. Stamps Delete / Duplicate /
/// Edit / per-target Connect actions onto every node card so
/// VoiceOver users get the same commands the mouse drag/context-menu paths
/// expose. Built as a `ViewModifier` instead of inline `.accessibilityAction`
/// calls so the action closures don't allocate on every node card update.
struct PolicyCanvasNodeAccessibilityActions: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let nodeID: String
  let connectTargets: [PolicyCanvasAccessibilityConnectTarget]
  let canPaste: Bool
  let openEditor: @MainActor () -> Void

  func body(content: Content) -> some View {
    content
      .accessibilityAction(named: Text("Delete")) {
        viewModel.select(.node(nodeID))
        viewModel.deleteNode(nodeID)
      }
      .accessibilityAction(named: Text("Duplicate")) {
        _ = viewModel.duplicateNode(nodeID)
      }
      .accessibilityAction(named: Text("Edit")) {
        viewModel.accessibilityOpenInspector(forNodeID: nodeID)
        openEditor()
      }
      .accessibilityAction(named: Text("Copy")) {
        if !viewModel.isSelected(.node(nodeID)) {
          viewModel.select(.node(nodeID))
        }
        _ = viewModel.copySelectionToClipboard()
      }
      .accessibilityAction(named: Text("Rename")) {
        viewModel.accessibilityOpenInspector(forNodeID: nodeID)
        openEditor()
      }
      .accessibilityAction(named: Text("Nudge Up")) {
        nudge(CGSize(width: 0, height: -10))
      }
      .accessibilityAction(named: Text("Nudge Down")) {
        nudge(CGSize(width: 0, height: 10))
      }
      .accessibilityAction(named: Text("Nudge Left")) {
        nudge(CGSize(width: -10, height: 0))
      }
      .accessibilityAction(named: Text("Nudge Right")) {
        nudge(CGSize(width: 10, height: 0))
      }
      .modifier(
        PolicyCanvasNodePasteAccessibilityAction(viewModel: viewModel, canPaste: canPaste)
      )
      .accessibilityActions {
        ForEach(connectTargets) { target in
          Button("Connect to \(target.displayName)") {
            _ = viewModel.accessibilityConnect(fromNodeID: nodeID, to: target.endpoint)
          }
        }
      }
  }

  private func nudge(_ delta: CGSize) {
    if !viewModel.isSelected(.node(nodeID)) {
      viewModel.select(.node(nodeID))
    }
    _ = viewModel.nudgeSelection(by: delta)
  }
}

private struct PolicyCanvasNodePasteAccessibilityAction: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let canPaste: Bool

  func body(content: Content) -> some View {
    if canPaste {
      content.accessibilityAction(named: Text("Paste")) {
        _ = viewModel.pasteFromClipboard()
      }
    } else {
      content
    }
  }
}

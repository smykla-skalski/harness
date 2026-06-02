import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  func createAutomationNode(
    item: PolicyCanvasAutomationPaletteItem,
    at point: CGPoint
  ) {
    let number = nextNodeNumber
    nextNodeNumber += 1
    var node = PolicyCanvasNode(
      id: "\(item.rawValue)-\(number)",
      title: item.title,
      kind: item.nodeKind,
      position: snapped(
        CGPoint(
          x: point.x - PolicyCanvasLayout.nodeSize.width / 2,
          y: point.y - PolicyCanvasLayout.nodeSize.height / 2
        )
      )
    )
    node.subtitle = item.subtitle
    node.groupID = containingGroupID(for: nodeCenter(node))
    node.policyKind = taskBoardPolicyNodeKind(for: item.nodeKind)
    node.automationBinding = item.automationBinding
    let priorSelection = selection
    mutate(.addNode(node, restoreSelection: priorSelection))
    notifyStatus("Added \(item.title) automation component")
  }
}

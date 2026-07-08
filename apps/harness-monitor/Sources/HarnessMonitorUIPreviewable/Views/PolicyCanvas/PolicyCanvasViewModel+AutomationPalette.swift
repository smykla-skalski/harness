import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

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
      position: .zero
    )
    let nodeSize = PolicyCanvasLayout.nodeSize(for: node)
    node.position = snapped(
      CGPoint(
        x: point.x - nodeSize.width / 2,
        y: point.y - nodeSize.height / 2
      )
    )
    node.subtitle = item.subtitle
    node.groupID = containingGroupID(for: nodeCenter(node))
    node.policyKind = policyNodeKind(for: item.nodeKind)
    node.automationBinding = item.automationBinding
    let priorSelection = selection
    mutate(.addNode(node, restoreSelection: priorSelection))
    notifyStatus("Added \(item.title) automation component")
  }
}

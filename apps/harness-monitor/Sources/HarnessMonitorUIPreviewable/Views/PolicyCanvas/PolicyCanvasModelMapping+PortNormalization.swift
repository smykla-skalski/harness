import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

func taskBoardPolicyPersistedPortTitle(
  _ portID: String,
  kind: PolicyCanvasPortKind
) -> String {
  let prefix = "\(kind.rawValue)-"
  guard portID.hasPrefix(prefix) else {
    return portID
  }
  return String(portID.dropFirst(prefix.count))
}

func policyCanvasPortID(
  title: String,
  kind: PolicyCanvasPortKind
) -> String {
  "\(kind.rawValue)-\(title)"
}

func policyCanvasUsesSwitchPortNormalization(_ node: PolicyCanvasNode) -> Bool {
  node.kind == .switch || taskBoardPolicyUsesSwitchPortNormalization(node.policyKind)
}

func taskBoardPolicyUsesSwitchPortNormalization(
  _ nodeKind: TaskBoardPolicyPipelineNodeKind?
) -> Bool {
  nodeKind?.kind == PolicyCanvasNodeKind.switch.rawValue
}

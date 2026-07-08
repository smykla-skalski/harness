import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

func policyPersistedPortTitle(
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
  node.kind == .switch || policyUsesSwitchPortNormalization(node.policyKind)
}

func policyUsesSwitchPortNormalization(
  _ nodeKind: PolicyGraphNodeKind?
) -> Bool {
  nodeKind?.discriminator == PolicyCanvasNodeKind.switch.rawValue
}

// Companion to PolicyCanvasModelMapping.swift.
// Internal port-ID and port-title normalisation helpers shared by
// the canvas-import and daemon-export conversion functions.
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

func policyCanvasPort(
  _ port: TaskBoardPolicyPipelinePort,
  nodeKind: PolicyGraphNodeKind,
  kind: PolicyCanvasPortKind
) -> PolicyCanvasPort {
  let title = policyCanvasImportedPortTitle(port.title, nodeKind: nodeKind, kind: kind)
  return PolicyCanvasPort(
    id: policyCanvasImportedPortID(port.id.rawValue, title: title, nodeKind: nodeKind, kind: kind),
    title: title,
    kind: kind
  )
}

func taskBoardPolicyPort(
  _ port: PolicyCanvasPort,
  nodeKind: PolicyGraphNodeKind,
  kind: PolicyCanvasPortKind
) -> TaskBoardPolicyPipelinePort {
  return TaskBoardPolicyPipelinePort(
    id: PolicyGraphPortId(
      taskBoardPolicyPersistedPortID(port.id, title: port.title, nodeKind: nodeKind, kind: kind)
    ),
    title: port.title
  )
}

func policyCanvasImportedPortID(
  _ portID: String,
  node: PolicyCanvasNode?,
  kind: PolicyCanvasPortKind
) -> String {
  guard let node, policyCanvasUsesSwitchPortNormalization(node) else {
    return portID
  }
  let ports = kind == .input ? node.inputPorts : node.outputPorts
  if let title = ports.first(where: { $0.id == portID })?.title {
    return policyCanvasPortID(title: title, kind: kind)
  }
  return policyCanvasPortID(
    title: taskBoardPolicyPersistedPortTitle(portID, kind: kind),
    kind: kind
  )
}

func policyCanvasImportedPortID(
  _ portID: String,
  title: String,
  nodeKind: PolicyGraphNodeKind,
  kind: PolicyCanvasPortKind
) -> String {
  guard taskBoardPolicyUsesSwitchPortNormalization(nodeKind) else {
    return portID
  }
  return policyCanvasPortID(title: title, kind: kind)
}

func policyCanvasImportedPortTitle(
  _ title: String,
  nodeKind: PolicyGraphNodeKind,
  kind: PolicyCanvasPortKind
) -> String {
  taskBoardPolicyUsesSwitchPortNormalization(nodeKind)
    ? taskBoardPolicyPersistedPortTitle(title, kind: kind)
    : title
}

func taskBoardPolicyPersistedPortID(
  _ portID: String,
  node: PolicyCanvasNode?,
  kind: PolicyCanvasPortKind
) -> String {
  guard let node, policyCanvasUsesSwitchPortNormalization(node) else {
    return portID
  }
  let ports = kind == .input ? node.inputPorts : node.outputPorts
  return ports.first(where: { $0.id == portID })?.title
    ?? taskBoardPolicyPersistedPortTitle(portID, kind: kind)
}

func taskBoardPolicyPersistedPortID(
  _ portID: String,
  title: String,
  nodeKind: PolicyGraphNodeKind,
  kind: PolicyCanvasPortKind
) -> String {
  guard taskBoardPolicyUsesSwitchPortNormalization(nodeKind) else {
    return portID
  }
  return title
}

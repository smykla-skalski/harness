import Foundation

// Map the generated host-machine wire type to the hand TaskBoardHostMachine. The
// shapes are identical (the agent modes already use the adopted TaskBoardAgentMode),
// so this is a straight pass-through; the wire type owns the daemon snake_case
// decode through the plain decoder.

extension TaskBoardHostMachine {
  public init(wire: MachineWire) {
    self.init(
      id: wire.id,
      label: wire.label,
      projectTypes: wire.projectTypes,
      agentModes: wire.agentModes,
      lastSeen: wire.lastSeen
    )
  }
}

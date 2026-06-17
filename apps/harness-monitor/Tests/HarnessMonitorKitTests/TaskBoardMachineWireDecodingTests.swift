import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the host machine type, generated from src/task_board/machines.rs.
/// The hand TaskBoardHostMachine decoded camelCase via convertFromSnakeCase; this
/// MachineWire owns the explicit snake_case decode through the plain decoder and the
/// host endpoints now route through it. The agent modes already use the adopted
/// TaskBoardAgentMode, so the mapping is a straight pass-through.
@Suite("Task board host machine wire type")
struct TaskBoardMachineWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a host machine and maps to the hand model")
  func decodesMachine() throws {
    let wire = try decoder.decode(MachineWire.self, from: Data(machinePayloadFixture.utf8))
    #expect(wire.id == "mac-1")
    #expect(wire.agentModes == [.headless, .interactive])

    let machine = TaskBoardHostMachine(wire: wire)
    #expect(machine.id == "mac-1")
    #expect(machine.label == "Studio")
    #expect(machine.projectTypes == ["rust", "swift"])
    #expect(machine.agentModes == [.headless, .interactive])
    #expect(machine.lastSeen == "2026-06-17T10:00:00Z")
  }

  @Test("defaults the collection fields when absent")
  func decodesMinimalMachine() throws {
    let wire = try decoder.decode(
      MachineWire.self,
      from: Data(#"{"id": "m0", "label": "Mini", "last_seen": "t"}"#.utf8)
    )
    #expect(wire.projectTypes.isEmpty)
    #expect(wire.agentModes.isEmpty)
    #expect(TaskBoardHostMachine(wire: wire).agentModes.isEmpty)
  }
}

private let machinePayloadFixture = """
  {
    "id": "mac-1",
    "label": "Studio",
    "project_types": ["rust", "swift"],
    "agent_modes": ["headless", "interactive"],
    "last_seen": "2026-06-17T10:00:00Z"
  }
  """

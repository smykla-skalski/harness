import Foundation

// Map the generated managed-agent snapshot umbrella to the hand enum. The adjacently-tagged
// wire decodes the kind + variant snapshot; each arm reuses its transport snapshot map (the
// acp arm throws because AcpAgentSnapshot re-decodes its JSON-passthrough status). This is the
// return type of nearly every managed-agent endpoint.

extension ManagedAgentSnapshot {
  public init(wire: ManagedAgentSnapshotWire) throws {
    switch wire {
    case .terminal(let snapshot):
      self = .terminal(AgentTuiSnapshot(wire: snapshot))
    case .codex(let snapshot):
      self = .codex(CodexRunSnapshot(wire: snapshot))
    case .acp(let snapshot):
      self = .acp(try AcpAgentSnapshot(wire: snapshot))
    }
  }
}

extension ManagedAgentListResponse {
  public init(wire: ManagedAgentListResponseWire) throws {
    self.init(agents: try wire.agents.map(ManagedAgentSnapshot.init(wire:)))
  }
}

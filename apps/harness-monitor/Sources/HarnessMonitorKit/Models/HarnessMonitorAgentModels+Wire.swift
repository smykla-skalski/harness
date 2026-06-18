import Foundation

// Map the generated persona wire types to the hand models. The shapes are thin mirrors;
// PersonaSymbol is the internally-tagged sf_symbol/asset enum, so its map switches over
// the two cases. These back the MonitorConfiguration.personas field.

extension PersonaSymbol {
  public init(wire: PersonaSymbolWire) {
    switch wire {
    case .sfSymbol(let name):
      self = .sfSymbol(name: name)
    case .asset(let name):
      self = .asset(name: name)
    }
  }
}

extension AgentPersona {
  public init(wire: AgentPersonaWire) {
    self.init(
      identifier: wire.identifier,
      name: wire.name,
      symbol: PersonaSymbol(wire: wire.symbol),
      description: wire.description
    )
  }
}

// SessionDetail.agents: AgentRegistration is `#[serde(try_from)]` its flat wire on the daemon, and
// the hand model already decodes that wire shape (renamed CodingKeys, runtime collapsed to a String
// via TaggedRuntime, managed_agent recombined from id + family). This map replays that logic onto
// the generated wire so the plain decoder drives it. role/status/managedAgentFamily are bare hand
// enums; runtime is a JSON_PASSTHROUGH JSONValue (bare string or {kind, id}); persona reuses the
// AgentPersonaWire map above. RuntimeCapabilities drops supports_readiness_signal (unmodeled).

extension HookIntegrationDescriptor {
  init(wire: HookIntegrationDescriptorWire) {
    self.init(
      name: wire.name,
      typicalLatencySeconds: Int(wire.typicalLatencySeconds),
      supportsContextInjection: wire.supportsContextInjection
    )
  }
}

extension RuntimeCapabilities {
  init(wire: RuntimeCapabilitiesWire) {
    self.init(
      runtime: wire.runtime,
      supportsNativeTranscript: wire.supportsNativeTranscript,
      supportsSignalDelivery: wire.supportsSignalDelivery,
      supportsContextInjection: wire.supportsContextInjection,
      typicalSignalLatencySeconds: Int(wire.typicalSignalLatencySeconds),
      hookPoints: wire.hookPoints.map(HookIntegrationDescriptor.init(wire:))
    )
  }
}

extension AgentRegistration {
  init(wire: AgentRegistrationWire) throws {
    self.init(
      agentId: wire.sessionAgentId,
      name: wire.name,
      runtime: try Self.runtimeName(from: wire.runtime),
      role: wire.role,
      capabilities: wire.capabilities,
      joinedAt: wire.joinedAt,
      updatedAt: wire.updatedAt,
      status: wire.status,
      agentSessionId: wire.runtimeSessionId,
      managedAgent: try Self.managedAgent(id: wire.managedAgentId, family: wire.managedAgentFamily),
      lastActivityAt: wire.lastActivityAt,
      currentTaskId: wire.currentTaskId,
      runtimeCapabilities: RuntimeCapabilities(wire: wire.runtimeCapabilities),
      persona: wire.persona.map(AgentPersona.init(wire:))
    )
  }

  /// Collapse the untagged RuntimeKind payload to the runtime name: a bare string is used as is,
  /// a `{kind, id}` object yields its id. Mirrors the hand init's TaggedRuntime decode.
  private static func runtimeName(from value: JSONValue) throws -> String {
    if case .string(let name) = value {
      return name
    }
    guard case .object(let fields) = value,
      case .string? = fields["kind"],
      case .string(let id)? = fields["id"]
    else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: [], debugDescription: "Invalid runtime kind payload")
      )
    }
    return id
  }

  /// Recombine the flat managed_agent_id + managed_agent_family pair, requiring both or neither.
  private static func managedAgent(
    id: String?,
    family: ManagedAgentKind?
  ) throws -> ManagedAgentRef? {
    switch (id, family) {
    case (nil, nil):
      return nil
    case (let id?, let family?):
      return ManagedAgentRef(kind: family, id: id)
    default:
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: [],
          debugDescription: "managed_agent_id and managed_agent_family must be provided together"
        )
      )
    }
  }
}

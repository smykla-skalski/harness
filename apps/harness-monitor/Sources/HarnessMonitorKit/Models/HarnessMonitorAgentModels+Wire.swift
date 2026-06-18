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

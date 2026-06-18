import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the agent persona, generated from agents.rs. The persona
/// decodes through the plain decoder; PersonaSymbol is internally tagged on "type"
/// (sf_symbol/asset) and decodes as a Swift enum with an associated name. These back the
/// MonitorConfiguration.personas field, rerouted with the /v1/config decode.
@Suite("Agent persona wire type")
struct AgentPersonaWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a persona with an sf-symbol through the plain decoder")
  func decodesSfSymbolPersona() throws {
    let wire = try decoder.decode(AgentPersonaWire.self, from: Data(sfSymbolFixture.utf8))
    #expect(wire.identifier == "code-reviewer")
    #expect(wire.name == "Code Reviewer")
    #expect(wire.description == "Reviews code changes")
    guard case .sfSymbol(let name) = wire.symbol else {
      Issue.record("expected an sf-symbol")
      return
    }
    #expect(name == "magnifyingglass.circle.fill")
  }

  @Test("decodes a persona with an asset symbol")
  func decodesAssetPersona() throws {
    let wire = try decoder.decode(AgentPersonaWire.self, from: Data(assetFixture.utf8))
    guard case .asset(let name) = wire.symbol else {
      Issue.record("expected an asset symbol")
      return
    }
    #expect(name == "persona-badge")
  }

  @Test("maps a decoded persona to the hand model")
  func mapsPersona() throws {
    let wire = try decoder.decode(AgentPersonaWire.self, from: Data(sfSymbolFixture.utf8))
    let persona = AgentPersona(wire: wire)
    #expect(persona.identifier == "code-reviewer")
    #expect(persona.name == "Code Reviewer")
    #expect(persona.description == "Reviews code changes")
    #expect(persona.symbol == .sfSymbol(name: "magnifyingglass.circle.fill"))
  }
}

private let sfSymbolFixture = """
  {
    "identifier": "code-reviewer",
    "name": "Code Reviewer",
    "symbol": { "type": "sf_symbol", "name": "magnifyingglass.circle.fill" },
    "description": "Reviews code changes"
  }
  """

private let assetFixture = """
  {
    "identifier": "designer",
    "name": "Designer",
    "symbol": { "type": "asset", "name": "persona-badge" },
    "description": "Shapes the visual design"
  }
  """

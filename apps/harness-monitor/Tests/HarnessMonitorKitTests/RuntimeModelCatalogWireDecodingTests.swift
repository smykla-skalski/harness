import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the runtime model catalog, generated from models/mod.rs.
/// The catalog decodes through the plain decoder; tier (RuntimeModelTier) and effort family
/// (EffortKind) reference the hand enums bare, and a model that omits effort_kind defaults
/// to .none. These back the MonitorConfiguration.runtimeModels field.
@Suite("Runtime model catalog wire type")
struct RuntimeModelCatalogWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a catalog with explicit and defaulted effort through the plain decoder")
  func decodesCatalog() throws {
    let wire = try decoder.decode(
      RuntimeModelCatalogWire.self, from: Data(catalogFixture.utf8)
    )
    #expect(wire.runtime == "claude")
    #expect(wire.default == "claude-opus-4-8")
    #expect(wire.cheapestFastest == "claude-haiku-4-5")
    #expect(wire.models.count == 2)

    let opus = try #require(wire.models.first)
    #expect(opus.id == "claude-opus-4-8")
    #expect(opus.tier == .max)
    #expect(opus.effortKind == .thinkingBudget)
    #expect(opus.effortValues == ["low", "medium", "high"])

    let haiku = wire.models[1]
    #expect(haiku.tier == .fast)
    #expect(haiku.effortKind == .none)
    #expect(haiku.effortValues.isEmpty)
  }

  @Test("maps a decoded catalog to the hand model")
  func mapsCatalog() throws {
    let wire = try decoder.decode(
      RuntimeModelCatalogWire.self, from: Data(catalogFixture.utf8)
    )
    let catalog = RuntimeModelCatalog(wire: wire)
    #expect(catalog.runtime == "claude")
    #expect(catalog.default == "claude-opus-4-8")
    #expect(catalog.cheapestFastest == "claude-haiku-4-5")
    let opus = try #require(catalog.models.first)
    #expect(opus.tier == .max)
    #expect(opus.effortKind == .thinkingBudget)
    #expect(catalog.models[1].effortKind == .none)
  }
}

private let catalogFixture = """
  {
    "runtime": "claude",
    "models": [
      {
        "id": "claude-opus-4-8",
        "display_name": "Opus 4.8",
        "tier": "max",
        "effort_kind": "thinking_budget",
        "effort_values": ["low", "medium", "high"]
      },
      {
        "id": "claude-haiku-4-5",
        "display_name": "Haiku 4.5",
        "tier": "fast"
      }
    ],
    "default": "claude-opus-4-8",
    "cheapest_fastest": "claude-haiku-4-5"
  }
  """

import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the `/v1/openrouter/models` response.
/// `OpenRouterModelCatalogResponse` is generated from the Rust wire types
/// (src/daemon/protocol/openrouter_models.rs) by examples/policy-codegen.rs, so
/// it spells explicit snake_case `CodingKeys` (`context_length`,
/// `supported_parameters`, `fetched_at`) and is decoded with the plain
/// `PolicyWireCoding.decoder` on both the HTTP and WebSocket transports. The
/// per-entry optionals/array carry `skip_serializing_if`, so a minimal entry
/// omits them entirely.
@Suite("OpenRouter model catalog decoding")
struct OpenRouterModelCatalogDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  private let daemonPayload = """
    {
      "models": [
        {
          "id": "anthropic/claude-opus-4",
          "name": "Claude Opus 4",
          "context_length": 200000,
          "supported_parameters": ["temperature", "max_tokens"]
        },
        {
          "id": "openai/gpt-5"
        }
      ],
      "fetched_at": "2026-06-16T10:00:00Z",
      "source": "live"
    }
    """

  @Test("decodes the full catalog with snake_case entry fields")
  func decodesFullCatalog() throws {
    let catalog = try decoder.decode(
      OpenRouterModelCatalogResponse.self,
      from: Data(daemonPayload.utf8)
    )

    #expect(catalog.fetchedAt == "2026-06-16T10:00:00Z")
    #expect(catalog.source == .live)
    #expect(catalog.models.count == 2)
    let first = try #require(catalog.models.first)
    #expect(first.id == "anthropic/claude-opus-4")
    #expect(first.name == "Claude Opus 4")
    #expect(first.contextLength == 200_000)
    #expect(first.supportedParameters == ["temperature", "max_tokens"])
  }

  @Test("a minimal entry omits the skip_serializing_if fields")
  func decodesMinimalEntry() throws {
    let catalog = try decoder.decode(
      OpenRouterModelCatalogResponse.self,
      from: Data(daemonPayload.utf8)
    )

    let minimal = catalog.models[1]
    #expect(minimal.id == "openai/gpt-5")
    #expect(minimal.name == nil)
    #expect(minimal.contextLength == nil)
    #expect(minimal.supportedParameters.isEmpty)
  }

  @Test("the catalog source enum maps each daemon value")
  func decodesEachSource() throws {
    for (raw, expected): (String, OpenRouterModelCatalogSource) in [
      ("live", .live), ("cache", .cache), ("fallback", .fallback),
    ] {
      let json = #"{"models":[],"fetched_at":"t","source":"\#(raw)"}"#
      let catalog = try decoder.decode(
        OpenRouterModelCatalogResponse.self,
        from: Data(json.utf8)
      )
      #expect(catalog.source == expected)
    }
  }
}

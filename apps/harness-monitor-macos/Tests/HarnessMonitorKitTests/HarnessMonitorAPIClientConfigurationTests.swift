import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor API client configuration", .serialized)
struct HarnessMonitorAPIClientConfigurationTests {
  @Test("configuration-backed picker data loads from /v1/config")
  func configurationBacksPickerCatalogs() async throws {
    ConfigurationURLProtocol.reset(mode: .withEmbeddedRuntimeProbe)
    let client = makeClient()

    let personas = try await client.personas()
    let catalogs = try await client.runtimeModelCatalogs()
    let descriptors = try await client.acpAgentDescriptors()
    let probe = try await client.runtimeProbeResults()

    #expect(personas.map(\.identifier) == ["debugger"])
    #expect(catalogs.map(\.runtime) == ["copilot"])
    #expect(descriptors.map(\.id) == ["copilot"])
    #expect(probe.probes.map(\.agentId) == ["copilot"])

    let paths = ConfigurationURLProtocol.requestedPaths
    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0 == "/v1/config" })
  }

  @Test("runtime probe falls back to dedicated endpoint when config omits it")
  func runtimeProbeFallsBackToDedicatedEndpoint() async throws {
    ConfigurationURLProtocol.reset(mode: .withoutRuntimeProbe)
    let client = makeClient()

    let probe = try await client.runtimeProbeResults()

    #expect(probe.probes.map(\.agentId) == ["copilot"])
    #expect(ConfigurationURLProtocol.requestedPaths == ["/v1/config", "/v1/runtimes/probe"])
  }
}

private func makeClient() -> HarnessMonitorAPIClient {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [ConfigurationURLProtocol.self]
  let session = URLSession(configuration: configuration)
  return HarnessMonitorAPIClient(
    connection: HarnessMonitorConnection(
      endpoint: URL(string: "http://127.0.0.1:9999")!,
      token: "token"
    ),
    session: session
  )
}

private final class ConfigurationURLProtocol: URLProtocol, @unchecked Sendable {
  enum Mode {
    case withEmbeddedRuntimeProbe
    case withoutRuntimeProbe
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var requested: [String] = []
  nonisolated(unsafe) private static var mode: Mode = .withEmbeddedRuntimeProbe

  static var requestedPaths: [String] {
    lock.withLock { requested }
  }

  static func reset(mode: Mode) {
    lock.withLock {
      self.mode = mode
      requested = []
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    let path = url.path
    let mode = Self.lock.withLock { () -> Mode in
      Self.requested.append(path)
      return Self.mode
    }

    let responseBody: String
    switch (path, mode) {
    case ("/v1/config", .withEmbeddedRuntimeProbe):
      responseBody = Self.configResponse(includeRuntimeProbe: true)
    case ("/v1/config", .withoutRuntimeProbe):
      responseBody = Self.configResponse(includeRuntimeProbe: false)
    case ("/v1/runtimes/probe", .withoutRuntimeProbe):
      responseBody = Self.runtimeProbeResponse
    default:
      respond(status: 404, body: #"{"error":"not-found"}"#, for: url)
      return
    }

    respond(status: 200, body: responseBody, for: url)
  }

  override func stopLoading() {}

  private func respond(status: Int, body: String, for url: URL) {
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func configResponse(includeRuntimeProbe: Bool) -> String {
    let runtimeProbe =
      includeRuntimeProbe
      ? #"""
        ,
        "runtime_probe": {
          "probes": [
            {
              "agent_id": "copilot",
              "display_name": "GitHub Copilot",
              "binary_present": true,
              "auth_state": "ready",
              "version": "1.0.0"
            }
          ],
          "checked_at": "2026-05-01T00:00:00Z"
        }
        """#
      : ""
    return #"""
      {
        "personas": [
          {
            "identifier": "debugger",
            "name": "Debugger",
            "symbol": {
              "type": "sf_symbol",
              "name": "ladybug"
            },
            "description": "Finds and fixes runtime issues."
          }
        ],
        "runtime_models": [
          {
            "runtime": "copilot",
            "models": [
              {
                "id": "gpt-5",
                "display_name": "GPT-5",
                "tier": "balanced"
              }
            ],
            "default": "gpt-5",
            "cheapest_fastest": "gpt-5"
          }
        ],
        "acp_agents": [
          {
            "id": "copilot",
            "display_name": "GitHub Copilot",
            "capabilities": ["project_access"],
            "launch_command": "copilot",
            "launch_args": ["agent"],
            "env_passthrough": ["GITHUB_TOKEN"],
            "doctor_probe": {
              "command": "copilot",
              "args": ["doctor"]
            },
            "prompt_timeout_seconds": 30
          }
        ]\#(runtimeProbe)
      }
      """#
  }

  private static let runtimeProbeResponse = #"""
    {
      "probes": [
        {
          "agent_id": "copilot",
          "display_name": "GitHub Copilot",
          "binary_present": true,
          "auth_state": "ready",
          "version": "1.0.0"
        }
      ],
      "checked_at": "2026-05-01T00:00:00Z"
    }
    """#
}

import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the daemon log-level response (generated into
/// SummariesWireTypes). The response decodes through the plain decoder and maps to the
/// hand LogLevelResponse; both /v1/daemon/log-level get and set are rerouted onto it.
@Suite("Log level wire type")
struct LogLevelWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes and maps the log-level response through the plain decoder")
  func decodesLogLevel() throws {
    let wire = try decoder.decode(LogLevelResponseWire.self, from: Data(logLevelFixture.utf8))
    #expect(wire.level == "info")
    #expect(wire.filter == "harness=info")

    let response = LogLevelResponse(wire: wire)
    #expect(response.level == "info")
    #expect(response.filter == "harness=info")
  }
}

private let logLevelFixture = """
  { "level": "info", "filter": "harness=info" }
  """

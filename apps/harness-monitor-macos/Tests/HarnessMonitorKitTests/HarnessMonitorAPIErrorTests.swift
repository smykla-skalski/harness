import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor API error formatting")
struct HarnessMonitorAPIErrorTests {
  @Test("Nested daemon error payloads normalize to the inner semantic message")
  func nestedDaemonErrorPayloadNormalizesToInnerMessage() {
    let error = HarnessMonitorAPIError.server(
      code: 400,
      message:
        #"{"error":{"details":null,"message":"session not active: managed agent 'agent-tui-1' not found","code":"KSRCLI090"}}"#
    )

    #expect(
      error.errorDescription
        == "Daemon error 400: session not active: managed agent 'agent-tui-1' not found"
    )
    #expect(error.serverMessage == "session not active: managed agent 'agent-tui-1' not found")
    #expect(error.serverSemanticCode == "KSRCLI090")
  }

  @Test("Plain daemon error payloads keep their original message")
  func plainDaemonErrorPayloadKeepsOriginalMessage() {
    let error = HarnessMonitorAPIError.server(code: 503, message: "daemon snapshot warming up")

    #expect(error.errorDescription == "Daemon error 503: daemon snapshot warming up")
    #expect(error.serverMessage == "daemon snapshot warming up")
    #expect(error.serverSemanticCode == nil)
  }
}

import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor API error formatting")
struct HarnessMonitorAPIErrorTests {
  @Test("Nested daemon error payloads normalize to the inner semantic message")
  func nestedDaemonErrorPayloadNormalizesToInnerMessage() {
    let message =
      #"{"error":{"details":null,"message":"session not active: "#
      + #"managed agent 'agent-tui-1' not found","code":"KSRCLI090"}}"#
    let error = HarnessMonitorAPIError.server(
      code: 400,
      message: message
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

  @Test("Sandbox disabled ACP errors use actionable host bridge copy")
  func sandboxDisabledAcpErrorsUseActionableHostBridgeCopy() {
    let error = HarnessMonitorAPIError.server(
      code: 501,
      message: "sandbox-disabled - acp.host-bridge"
    )

    #expect(
      error.errorDescription
        == "ACP sessions can't make tool calls because the shared host bridge isn't running. Start the host bridge and try again."
    )
    #expect(error.serverMessage == "sandbox-disabled - acp.host-bridge")
    #expect(error.serverSemanticCode == nil)
  }
}

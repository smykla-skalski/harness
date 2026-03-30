import Testing

@testable import HarnessKit

@Suite("Server-sent event parsing")
struct ServerSentEventsTests {
  @Test("Parses a single event frame")
  func parsesSingleEvent() {
    var parser = ServerSentEventParser()

    #expect(parser.push(line: "event: session_updated") == nil)
    #expect(parser.push(line: "data: {\"event\":\"session_updated\"}") == nil)

    let frame = parser.push(line: "")
    #expect(frame?.event == "session_updated")
    #expect(frame?.data == #"{"event":"session_updated"}"#)
  }

  @Test("Combines multiline payloads")
  func combinesMultilinePayloads() {
    var parser = ServerSentEventParser()

    #expect(parser.push(line: "data: {") == nil)
    #expect(parser.push(line: "data: \"event\":\"ready\"") == nil)

    let frame = parser.push(line: "")
    #expect(frame?.data == "{\n\"event\":\"ready\"")
  }
}

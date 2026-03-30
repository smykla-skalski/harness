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

  @Test("Finish flushes a partial frame without trailing blank line")
  func finishFlushesPartialFrame() {
    var parser = ServerSentEventParser()

    #expect(parser.push(line: "event: heartbeat") == nil)
    #expect(parser.push(line: "data: {}") == nil)

    let frame = parser.finish()
    #expect(frame?.event == "heartbeat")
    #expect(frame?.data == "{}")
  }

  @Test("Finish returns nil when no data has been accumulated")
  func finishReturnsNilWithNoData() {
    var parser = ServerSentEventParser()
    #expect(parser.finish() == nil)
  }

  @Test("Ignores comment lines starting with colon")
  func ignoresCommentLines() {
    var parser = ServerSentEventParser()

    #expect(parser.push(line: ": this is a comment") == nil)
    #expect(parser.push(line: "data: actual") == nil)

    let frame = parser.push(line: "")
    #expect(frame?.data == "actual")
    #expect(frame?.event == nil)
  }
}

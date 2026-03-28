import HarnessMonitorKit
import XCTest

final class ServerSentEventsTests: XCTestCase {
  func testParsesSingleEvent() {
    var parser = ServerSentEventParser()

    XCTAssertNil(parser.push(line: "event: session_updated"))
    XCTAssertNil(parser.push(line: "data: {\"event\":\"session_updated\"}"))

    let frame = parser.push(line: "")
    XCTAssertEqual(frame?.event, "session_updated")
    XCTAssertEqual(frame?.data, #"{"event":"session_updated"}"#)
  }

  func testCombinesMultilinePayloads() {
    var parser = ServerSentEventParser()

    XCTAssertNil(parser.push(line: "data: {"))
    XCTAssertNil(parser.push(line: "data: \"event\":\"ready\""))

    let frame = parser.push(line: "")
    XCTAssertEqual(frame?.data, "{\n\"event\":\"ready\"")
  }
}

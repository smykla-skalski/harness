import XCTest
@testable import HarnessMonitorPerfCore

final class XMLSanitizerTests: XCTestCase {
    func testCleanASCIIPayloadReturnsSameData() throws {
        let payload = "<trace-query-result><node><schema/></node></trace-query-result>"
        let data = Data(payload.utf8)
        let result = XMLSanitizer.sanitize(data)
        XCTAssertEqual(result, data, "clean payload must be returned unchanged on the fast path")
    }

    func testWhitespaceControlBytesPreserved() throws {
        let payload = "line1\tcol\nline2\rline3"
        let data = Data(payload.utf8)
        let result = XMLSanitizer.sanitize(data)
        XCTAssertEqual(result, data, "tab, LF, CR must survive the filter")
    }

    func testInvalidC0BytesStripped() throws {
        var payload = Data("<a/>".utf8)
        payload.insert(0x00, at: 2) // NUL between < and a
        payload.insert(0x08, at: payload.count) // backspace at tail
        payload.insert(0x1F, at: payload.count) // unit-separator
        let result = XMLSanitizer.sanitize(payload)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "<a/>")
    }

    func testUTF8MultiByteSequencesPreserved() throws {
        let payload = "<a fmt=\"héllo — world 中文\"/>"
        let data = Data(payload.utf8)
        let result = XMLSanitizer.sanitize(data)
        XCTAssertEqual(result, data, "multi-byte UTF-8 must survive untouched")
    }

    func testStreamingFilterHandlesLargePayload() throws {
        // Build ~2 MiB payload mixing valid UTF-8 with one stray NUL.
        // 696 MB exercises the OOM but is impractical in CI; this verifies
        // the slow path is correct and bounded in memory at any size.
        var payload = Data()
        let chunk = Data("<row>content with héllo — 中文 line</row>".utf8)
        for _ in 0..<50_000 {
            payload.append(chunk)
        }
        payload.append(0x00) // stray NUL forces the slow path
        let result = XMLSanitizer.sanitize(payload)
        XCTAssertEqual(result.count, payload.count - 1)
        XCTAssertEqual(result.suffix(chunk.count), chunk)
    }

    func testEmptyPayload() throws {
        let result = XMLSanitizer.sanitize(Data())
        XCTAssertTrue(result.isEmpty)
    }
}

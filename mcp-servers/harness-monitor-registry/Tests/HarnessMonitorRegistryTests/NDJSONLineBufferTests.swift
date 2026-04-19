import Foundation
import Testing
@testable import HarnessMonitorRegistry

@Suite("NDJSONLineBuffer")
struct NDJSONLineBufferTests {
  @Test("splits complete lines and buffers partial")
  func splitAndBuffer() {
    var buffer = NDJSONLineBuffer()
    let chunk1 = Data("{\"a\":1}\n{\"b".utf8)
    let lines1 = buffer.append(chunk1)
    #expect(lines1.map { String(data: $0, encoding: .utf8) } == ["{\"a\":1}"])
    #expect(buffer.pendingByteCount == 3)

    let chunk2 = Data(":2}\n".utf8)
    let lines2 = buffer.append(chunk2)
    #expect(lines2.map { String(data: $0, encoding: .utf8) } == ["{\"b:2}"])
    #expect(buffer.pendingByteCount == 0)
  }

  @Test("drops empty lines")
  func dropsEmpty() {
    var buffer = NDJSONLineBuffer()
    let lines = buffer.append(Data("\n\n{\"x\":1}\n\n".utf8))
    #expect(lines.map { String(data: $0, encoding: .utf8) } == ["{\"x\":1}"])
  }
}

@Suite("RegistryWireCodec")
struct RegistryWireCodecTests {
  @Test("round-trips request decode")
  func requestDecode() throws {
    let raw = Data("{\"id\":7,\"op\":\"listElements\",\"windowID\":42,\"kind\":\"button\"}".utf8)
    let request = try RegistryWireCodec.decodeRequest(raw)
    #expect(request.id == 7)
    #expect(request.op == .listElements)
    #expect(request.windowID == 42)
    #expect(request.kind == .button)
  }

  @Test("encodes success response as ok:true envelope")
  func encodeSuccess() throws {
    let response = RegistryResponse.success(
      id: 11,
      result: .getElement(
        GetElementResult(
          element: RegistryElement(
            identifier: "btn",
            kind: .button,
            frame: RegistryRect(x: 0, y: 0, width: 10, height: 10)
          )
        )
      )
    )
    let encoded = try RegistryWireCodec.encodeResponse(response)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(json.contains("\"ok\":true"))
    #expect(json.contains("\"id\":11"))
    #expect(json.contains("\"identifier\":\"btn\""))
  }

  @Test("encodes failure response with error code")
  func encodeFailure() throws {
    let response = RegistryResponse.failure(
      id: 99,
      error: RegistryErrorPayload(code: "not-found", message: "missing")
    )
    let encoded = try RegistryWireCodec.encodeResponse(response)
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(json.contains("\"ok\":false"))
    #expect(json.contains("\"code\":\"not-found\""))
  }
}

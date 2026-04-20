@testable import HarnessMonitorKit
import XCTest

final class SessionStartRequestTests: XCTestCase {
  func testEncodesSnakeCase() throws {
    let req = SessionStartRequest(
      title: "t",
      context: "c",
      runtime: "claude",
      sessionId: nil,
      projectDir: "B-abc",
      policyPreset: nil,
      baseRef: "main"
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(req)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(json.contains("\"base_ref\":\"main\""))
    XCTAssertTrue(json.contains("\"project_dir\":\"B-abc\""))
  }

  func testOmitsNilBaseRef() throws {
    let req = SessionStartRequest(
      title: "t",
      context: "c",
      runtime: "claude",
      sessionId: nil,
      projectDir: "B-abc",
      policyPreset: nil,
      baseRef: nil
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(req)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("base_ref"))
  }
}

import XCTest

@testable import HarnessMonitorKit

final class SessionDiscoveryProbeTests: XCTestCase {
  func testProbeAcceptsValidSession() async throws {
    let fixture = try SessionProbeFixture.makeValid()
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])
    let preview = try await probe.probe(url: fixture.url)
    XCTAssertEqual(preview.sessionId, "abc12345")
    XCTAssertEqual(preview.projectName, "demo")
  }

  func testProbeReportsAlreadyAttached() async throws {
    let fixture = try SessionProbeFixture.makeValid()
    let probe = SessionDiscoveryProbe(existingSessionIDs: ["abc12345"])
    do {
      _ = try await probe.probe(url: fixture.url)
      XCTFail("expected already-attached")
    } catch let failure as SessionDiscoveryProbe.Failure {
      guard case .alreadyAttached(let sid) = failure else {
        XCTFail("wrong failure: \(failure)")
        return
      }
      XCTAssertEqual(sid, "abc12345")
    }
  }

  func testProbeRejectsMissingWorkspace() async throws {
    let fixture = try SessionProbeFixture.makeValid()
    try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("workspace"))
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])
    do {
      _ = try await probe.probe(url: fixture.url)
      XCTFail("expected missing workspace failure")
    } catch let failure as SessionDiscoveryProbe.Failure {
      guard case .notAHarnessSession = failure else {
        XCTFail("wrong failure: \(failure)")
        return
      }
    }
  }

  func testProbeRejectsSchemaMismatch() async throws {
    let fixture = try SessionProbeFixture.makeValid()
    try fixture.rewriteSchema(to: 7)
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])
    do {
      _ = try await probe.probe(url: fixture.url)
      XCTFail("expected schema mismatch")
    } catch let failure as SessionDiscoveryProbe.Failure {
      guard case .unsupportedSchemaVersion(let found, let supported) = failure else {
        XCTFail("wrong failure: \(failure)")
        return
      }
      XCTAssertEqual(found, 7)
      XCTAssertEqual(supported, 9)
    }
  }

  func testProbeParsesFractionalSecondsCreatedAt() async throws {
    let fixture = try SessionProbeFixture.makeValid()
    try fixture.rewriteField("created_at", to: "2026-04-20T12:34:56.123456Z")
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])
    let preview = try await probe.probe(url: fixture.url)
    XCTAssertNotEqual(preview.createdAt, Date(timeIntervalSince1970: 0))
  }

  func testProbeRejectsMissingOriginPath() async throws {
    let fixture = try SessionProbeFixture.makeValid()
    try fixture.removeField("origin_path")
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])
    do {
      _ = try await probe.probe(url: fixture.url)
      XCTFail("expected missing origin_path failure")
    } catch let failure as SessionDiscoveryProbe.Failure {
      guard case .notAHarnessSession(let reason) = failure else {
        XCTFail("wrong failure: \(failure)")
        return
      }
      XCTAssertEqual(reason, "missing origin_path")
    }
  }

  func testProbeReportsTypedOriginMismatch() async throws {
    let fixture = try SessionProbeFixture.makeValid()
    try fixture.rewriteField("origin_path", to: "/Users/me/src/other")
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])

    do {
      _ = try await probe.probe(url: fixture.url)
      XCTFail("expected typed origin mismatch")
    } catch let failure as SessionDiscoveryProbe.Failure {
      guard case .belongsToAnotherProject(let expected, let found) = failure else {
        XCTFail("wrong failure: \(failure)")
        return
      }
      XCTAssertEqual(expected, "/Users/me/src/kuma")
      XCTAssertEqual(found, "/Users/me/src/other")
    }
  }
}

struct SessionProbeFixture {
  let url: URL

  static func makeValid() throws -> Self {
    let tmp = try FileManager.default.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask,
      appropriateFor: FileManager.default.temporaryDirectory,
      create: true
    ).appendingPathComponent("session-\(UUID().uuidString)")
    let sessionDir = tmp.appendingPathComponent("kuma/abc12345")
    try FileManager.default.createDirectory(
      at: sessionDir.appendingPathComponent("workspace"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sessionDir.appendingPathComponent("memory"),
      withIntermediateDirectories: true
    )
    let origin = "/Users/me/src/kuma"
    let state = """
      {"schema_version":9,"session_id":"abc12345","project_name":"demo","title":"demo session",\
      "origin_path":"\(origin)","worktree_path":"","shared_path":"","branch_ref":"harness/abc12345",\
      "status":"active","context":"c","created_at":"2026-04-20T12:34:56Z",\
      "updated_at":"2026-04-20T12:34:56Z","agents":{},"tasks":{},\
      "metrics":{"agent_count":0,"active_agent_count":0,"idle_agent_count":0,\
      "open_task_count":0,"in_progress_task_count":0,"blocked_task_count":0,\
      "completed_task_count":0}}
      """
    try Data(state.utf8).write(to: sessionDir.appendingPathComponent("state.json"))
    try Data(origin.utf8).write(to: sessionDir.appendingPathComponent(".origin"))
    return Self(url: sessionDir)
  }

  func rewriteSchema(to version: Int) throws {
    let stateURL = url.appendingPathComponent("state.json")
    let data = try Data(contentsOf: stateURL)
    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    json["schema_version"] = version
    let rewritten = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    try rewritten.write(to: stateURL)
  }

  func rewriteField(_ key: String, to value: Any) throws {
    let stateURL = url.appendingPathComponent("state.json")
    let data = try Data(contentsOf: stateURL)
    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "SessionProbeFixture", code: 1)
    }
    json[key] = value
    let rewritten = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    try rewritten.write(to: stateURL)
  }

  func removeField(_ key: String) throws {
    let stateURL = url.appendingPathComponent("state.json")
    let data = try Data(contentsOf: stateURL)
    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(domain: "SessionProbeFixture", code: 1)
    }
    json.removeValue(forKey: key)
    let rewritten = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    try rewritten.write(to: stateURL)
  }
}

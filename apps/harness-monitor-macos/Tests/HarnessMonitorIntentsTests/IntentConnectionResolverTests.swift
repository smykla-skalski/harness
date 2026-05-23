import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class IntentConnectionResolverTests: XCTestCase {
  private var temporaryDirectoryURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-intents-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    temporaryDirectoryURL = base
  }

  override func tearDownWithError() throws {
    if let url = temporaryDirectoryURL {
      try? FileManager.default.removeItem(at: url)
    }
    temporaryDirectoryURL = nil
    try super.tearDownWithError()
  }

  func testResolveReturnsConnectionFromManifestAndTokenFile() throws {
    let daemonRoot = temporaryDirectoryURL!
    try writeManifest(
      DaemonManifest(
        version: "0.0.0",
        pid: 1234,
        endpoint: "http://127.0.0.1:34567",
        startedAt: "2026-05-23T12:00:00Z",
        tokenPath: "auth-token"
      ),
      to: daemonRoot.appendingPathComponent("manifest.json")
    )
    try writeAuthToken("secret-token\n", to: daemonRoot.appendingPathComponent("auth-token"))

    let connection = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)

    XCTAssertEqual(connection.endpoint, URL(string: "http://127.0.0.1:34567"))
    XCTAssertEqual(connection.token, "secret-token")
  }

  func testResolveResolvesAbsoluteManifestTokenPath() throws {
    let daemonRoot = temporaryDirectoryURL!
    let absoluteTokenURL = daemonRoot
      .appendingPathComponent("nested", isDirectory: true)
      .appendingPathComponent("token.txt")
    try FileManager.default.createDirectory(
      at: absoluteTokenURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeManifest(
      DaemonManifest(
        version: "0.0.0",
        pid: 1234,
        endpoint: "http://127.0.0.1:34567",
        startedAt: "2026-05-23T12:00:00Z",
        tokenPath: absoluteTokenURL.path
      ),
      to: daemonRoot.appendingPathComponent("manifest.json")
    )
    try writeAuthToken("absolute-token", to: absoluteTokenURL)

    let connection = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)

    XCTAssertEqual(connection.token, "absolute-token")
  }

  func testResolveFallsBackToAuthTokenFileWhenManifestTokenPathBlank() throws {
    let daemonRoot = temporaryDirectoryURL!
    try writeManifest(
      DaemonManifest(
        version: "0.0.0",
        pid: 1234,
        endpoint: "http://127.0.0.1:34567",
        startedAt: "2026-05-23T12:00:00Z",
        tokenPath: ""
      ),
      to: daemonRoot.appendingPathComponent("manifest.json")
    )
    try writeAuthToken("fallback-token", to: daemonRoot.appendingPathComponent("auth-token"))

    let connection = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)

    XCTAssertEqual(connection.token, "fallback-token")
  }

  func testResolveThrowsManifestUnreadableWhenMissing() throws {
    let daemonRoot = temporaryDirectoryURL!
    do {
      _ = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)
      XCTFail("expected manifestUnreadable")
    } catch let error as IntentDaemonError {
      guard case .manifestUnreadable = error else {
        XCTFail("expected manifestUnreadable, got \(error)")
        return
      }
    }
  }

  func testResolveThrowsManifestMalformedWhenJSONInvalid() throws {
    let daemonRoot = temporaryDirectoryURL!
    try Data("{not json".utf8).write(to: daemonRoot.appendingPathComponent("manifest.json"))

    do {
      _ = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)
      XCTFail("expected manifestMalformed")
    } catch let error as IntentDaemonError {
      guard case .manifestMalformed = error else {
        XCTFail("expected manifestMalformed, got \(error)")
        return
      }
    }
  }

  func testResolveThrowsInvalidEndpointForUnknownScheme() throws {
    let daemonRoot = temporaryDirectoryURL!
    try writeManifest(
      DaemonManifest(
        version: "0.0.0",
        pid: 1234,
        endpoint: "ftp://127.0.0.1:34567",
        startedAt: "2026-05-23T12:00:00Z",
        tokenPath: "auth-token"
      ),
      to: daemonRoot.appendingPathComponent("manifest.json")
    )
    try writeAuthToken("token", to: daemonRoot.appendingPathComponent("auth-token"))

    do {
      _ = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)
      XCTFail("expected invalidEndpoint")
    } catch let error as IntentDaemonError {
      guard case .invalidEndpoint = error else {
        XCTFail("expected invalidEndpoint, got \(error)")
        return
      }
    }
  }

  func testResolveThrowsAuthTokenMissingWhenFileAbsent() throws {
    let daemonRoot = temporaryDirectoryURL!
    try writeManifest(
      DaemonManifest(
        version: "0.0.0",
        pid: 1234,
        endpoint: "http://127.0.0.1:34567",
        startedAt: "2026-05-23T12:00:00Z",
        tokenPath: "auth-token"
      ),
      to: daemonRoot.appendingPathComponent("manifest.json")
    )

    do {
      _ = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)
      XCTFail("expected authTokenMissing")
    } catch let error as IntentDaemonError {
      guard case .authTokenMissing = error else {
        XCTFail("expected authTokenMissing, got \(error)")
        return
      }
    }
  }

  func testResolveThrowsAuthTokenEmptyWhenFileBlank() throws {
    let daemonRoot = temporaryDirectoryURL!
    try writeManifest(
      DaemonManifest(
        version: "0.0.0",
        pid: 1234,
        endpoint: "http://127.0.0.1:34567",
        startedAt: "2026-05-23T12:00:00Z",
        tokenPath: "auth-token"
      ),
      to: daemonRoot.appendingPathComponent("manifest.json")
    )
    try writeAuthToken("   \n\t  ", to: daemonRoot.appendingPathComponent("auth-token"))

    do {
      _ = try IntentConnectionResolver.resolve(daemonRoot: daemonRoot)
      XCTFail("expected authTokenEmpty")
    } catch let error as IntentDaemonError {
      guard case .authTokenEmpty = error else {
        XCTFail("expected authTokenEmpty, got \(error)")
        return
      }
    }
  }

  // MARK: - helpers

  private func writeManifest(_ manifest: DaemonManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: url)
  }

  private func writeAuthToken(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
  }
}

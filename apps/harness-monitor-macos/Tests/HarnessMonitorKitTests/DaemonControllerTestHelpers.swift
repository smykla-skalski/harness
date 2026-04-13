import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

func withTempDaemonFixture(
  pid: UInt32,
  endpoint: String = "http://127.0.0.1:65534",
  tokenPathFactory: ((URL) throws -> URL)? = nil,
  perform: (HarnessMonitorEnvironment) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("daemon-controller-tests-\(UUID().uuidString)", isDirectory: true)
  let daemonHome = root.appendingPathComponent("data-home", isDirectory: true)
  let daemonRoot =
    daemonHome
    .appendingPathComponent("harness", isDirectory: true)
    .appendingPathComponent("daemon", isDirectory: true)
  try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let tokenPath: URL
  if let tokenPathFactory {
    tokenPath = try tokenPathFactory(daemonRoot)
  } else {
    tokenPath = daemonRoot.appendingPathComponent("auth-token")
    try writeTokenFixture(to: tokenPath)
  }

  let manifest = DaemonManifest(
    version: "19.4.1",
    pid: Int(pid),
    endpoint: endpoint,
    startedAt: "2026-04-11T12:00:00Z",
    tokenPath: tokenPath.path,
    sandboxed: true,
    hostBridge: HostBridgeManifest()
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.keyEncodingStrategy = .convertToSnakeCase
  let manifestData = try encoder.encode(manifest)
  try manifestData.write(to: daemonRoot.appendingPathComponent("manifest.json"))

  let environment = HarnessMonitorEnvironment(
    values: [HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonHome.path],
    homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
  )
  try await perform(environment)
}

func writeTokenFixture(
  _ value: String = "test-token",
  to url: URL,
  permissions: Int = 0o600
) throws {
  try value.write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

func rewriteTempDaemonFixtureManifest(
  environment: HarnessMonitorEnvironment,
  pid: UInt32,
  endpoint: String,
  startedAt: String
) throws {
  let tokenPath = HarnessMonitorPaths.authTokenURL(using: environment)
  let manifest = DaemonManifest(
    version: "19.4.1",
    pid: Int(pid),
    endpoint: endpoint,
    startedAt: startedAt,
    tokenPath: tokenPath.path,
    sandboxed: true,
    hostBridge: HostBridgeManifest()
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.keyEncodingStrategy = .convertToSnakeCase
  let manifestData = try encoder.encode(manifest)
  try manifestData.write(to: HarnessMonitorPaths.manifestURL(using: environment))
}

final class RecordingLaunchAgentManager: DaemonLaunchAgentManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var protectedState: DaemonLaunchAgentRegistrationState
  private let registerResult: DaemonLaunchAgentRegistrationState
  private var protectedRegisterCallCount = 0
  private var protectedUnregisterCallCount = 0

  init(
    state: DaemonLaunchAgentRegistrationState,
    registerResult: DaemonLaunchAgentRegistrationState = .enabled
  ) {
    self.protectedState = state
    self.registerResult = registerResult
  }

  var state: DaemonLaunchAgentRegistrationState {
    lock.withLock { protectedState }
  }

  var registerCallCount: Int {
    lock.withLock { protectedRegisterCallCount }
  }

  var unregisterCallCount: Int {
    lock.withLock { protectedUnregisterCallCount }
  }

  func registrationState() -> DaemonLaunchAgentRegistrationState {
    lock.withLock { protectedState }
  }

  func register() throws {
    lock.withLock {
      protectedRegisterCallCount += 1
      protectedState = registerResult
    }
  }

  func unregister() throws {
    lock.withLock {
      protectedUnregisterCallCount += 1
      protectedState = .notRegistered
    }
  }
}

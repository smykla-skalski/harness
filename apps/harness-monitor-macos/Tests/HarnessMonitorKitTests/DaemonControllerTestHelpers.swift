import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

func withTempDaemonFixture(
  pid: UInt32,
  version: String = "19.4.1",
  endpoint: String = "http://127.0.0.1:65534",
  binaryStamp: DaemonBinaryStampFixture? = nil,
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

  let manifest = DaemonManifestFixture(
    version: version,
    pid: Int(pid),
    endpoint: endpoint,
    startedAt: "2026-04-11T12:00:00Z",
    tokenPath: tokenPath.path,
    sandboxed: true,
    hostBridge: HostBridgeManifest(),
    binaryStamp: binaryStamp
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
  version: String = "19.4.1",
  endpoint: String,
  startedAt: String,
  binaryStamp: DaemonBinaryStampFixture? = nil
) throws {
  let tokenPath = HarnessMonitorPaths.authTokenURL(using: environment)
  let manifest = DaemonManifestFixture(
    version: version,
    pid: Int(pid),
    endpoint: endpoint,
    startedAt: startedAt,
    tokenPath: tokenPath.path,
    sandboxed: true,
    hostBridge: HostBridgeManifest(),
    binaryStamp: binaryStamp
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.keyEncodingStrategy = .convertToSnakeCase
  let manifestData = try encoder.encode(manifest)
  try manifestData.write(to: HarnessMonitorPaths.manifestURL(using: environment))
}

func withSignalIgnoringSleepProcessPID(
  durationSeconds: Int = 60,
  perform: (UInt32) async throws -> Void
) async throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", "trap '' TERM; sleep \(durationSeconds)"]
  try process.run()
  defer {
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }
  try await perform(UInt32(process.processIdentifier))
}

struct DaemonBinaryStampFixture: Codable, Equatable {
  let helperPath: String
  let deviceIdentifier: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeIntervalSince1970: Double
}

private struct DaemonManifestFixture: Codable {
  let version: String
  let pid: Int
  let endpoint: String
  let startedAt: String
  let tokenPath: String
  let sandboxed: Bool
  let hostBridge: HostBridgeManifest
  let revision: UInt64
  let updatedAt: String?
  let binaryStamp: DaemonBinaryStampFixture?

  init(
    version: String,
    pid: Int,
    endpoint: String,
    startedAt: String,
    tokenPath: String,
    sandboxed: Bool,
    hostBridge: HostBridgeManifest,
    revision: UInt64 = 0,
    updatedAt: String? = nil,
    binaryStamp: DaemonBinaryStampFixture? = nil
  ) {
    self.version = version
    self.pid = pid
    self.endpoint = endpoint
    self.startedAt = startedAt
    self.tokenPath = tokenPath
    self.sandboxed = sandboxed
    self.hostBridge = hostBridge
    self.revision = revision
    self.updatedAt = updatedAt
    self.binaryStamp = binaryStamp
  }
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

final class HookedLaunchAgentManager: DaemonLaunchAgentManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var protectedState: DaemonLaunchAgentRegistrationState
  private let registerResult: DaemonLaunchAgentRegistrationState
  private let onRegister: @Sendable () throws -> Void
  private let onUnregister: @Sendable () throws -> Void
  private var protectedRegisterCallCount = 0
  private var protectedUnregisterCallCount = 0

  init(
    state: DaemonLaunchAgentRegistrationState,
    registerResult: DaemonLaunchAgentRegistrationState = .enabled,
    onRegister: @escaping @Sendable () throws -> Void = {},
    onUnregister: @escaping @Sendable () throws -> Void = {}
  ) {
    self.protectedState = state
    self.registerResult = registerResult
    self.onRegister = onRegister
    self.onUnregister = onUnregister
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
    try onRegister()
    lock.withLock {
      protectedRegisterCallCount += 1
      protectedState = registerResult
    }
  }

  func unregister() throws {
    try onUnregister()
    lock.withLock {
      protectedUnregisterCallCount += 1
      protectedState = .notRegistered
    }
  }
}

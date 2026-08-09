import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed daemon quiescence", .serialized)
struct LegacyManagedDaemonQuiescenceTests {
  @Test("Managed helper identity accepts isolated lanes and known legacy helpers")
  func managedHelperIdentityAcceptsIsolatedLanes() {
    #expect(
      DaemonController.isTrustedManagedHelperIdentifier(
        "Q498EB36N4.io.harnessmonitor.agent-fix-automation-6245e82a"
      )
    )
    #expect(
      DaemonController.isTrustedManagedHelperIdentifier(
        "Q498EB36N4.io.harnessmonitor.daemon"
      )
    )
    #expect(
      DaemonController.isTrustedManagedHelperIdentifier(
        "Q498EB36N4.io.harnessmonitor.agentforeign"
      ) == false
    )
  }

  @Test("Controller fences and stops every trusted live managed daemon")
  func controllerFencesAndStopsTrustedManagedDaemon() async throws {
    let client = RecordingHarnessClient()
    try await withTempDaemonFixture(pid: UInt32(getpid())) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        sessionFactory: { _ in client }
      )

      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
    }

    let requests = client.lock.withLock {
      client.policyCanvasSpawnKillSwitchRequests
    }
    #expect(requests == [true])
    #expect(client.lock.withLock { client.stopDaemonRequestCount } == 1)
  }

  @Test("Controller attempts every managed daemon after an earlier stop fails")
  func controllerAttemptsEveryManagedDaemonAfterStopFailure() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "all")
    defer { fixture.remove() }
    let roots = HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment)
    let first = try #require(roots.first)
    let second = try #require(roots.first { $0.rootURL != first.rootURL })
    try fixture.writeManifest(at: first, endpoint: "http://127.0.0.1:65101")
    try fixture.writeManifest(at: second, endpoint: "http://127.0.0.1:65102")
    let failingClient = RecordingHarnessClient()
    failingClient.stopDaemonError = ManagedDaemonQuiescenceTestError.stopFailed
    let succeedingClient = RecordingHarnessClient()
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      sessionFactory: { connection in
        connection.endpoint.port == 65_101 ? failingClient : succeedingClient
      }
    )

    await #expect(throws: DaemonControlError.self) {
      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
    }

    #expect(failingClient.lock.withLock { failingClient.stopDaemonRequestCount } == 1)
    #expect(succeedingClient.lock.withLock { succeedingClient.stopDaemonRequestCount } == 1)
  }

  @Test("Controller waits for a starting managed daemon to publish and stop")
  func controllerWaitsForStartingManagedDaemon() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "starting")
    defer { fixture.remove() }
    let candidate = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    let lockFD = try fixture.lock(candidate)
    defer { _ = Darwin.close(lockFD) }
    defer { _ = testBSDFileLock(lockFD, LOCK_UN) }
    let client = RecordingHarnessClient()
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      sessionFactory: { _ in client }
    )
    let completion = ManagedDaemonQuiescenceCompletion()
    let quiescence = Task {
      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
      await completion.markComplete()
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(client.lock.withLock { client.stopDaemonRequestCount } == 0)
    try fixture.writeManifest(at: candidate, endpoint: "http://127.0.0.1:65103")
    while client.lock.withLock({ client.stopDaemonRequestCount }) == 0 {
      try await Task.sleep(for: .milliseconds(20))
    }
    let completedBeforeRelease = await completion.isComplete
    #expect(completedBeforeRelease == false)
    _ = testBSDFileLock(lockFD, LOCK_UN)
    try await quiescence.value
    let completedAfterRelease = await completion.isComplete
    #expect(completedAfterRelease)
  }

  @Test("Controller rejects a starting daemon that never publishes a manifest")
  func controllerRejectsStartingDaemonWithoutManifest() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "stuck")
    defer { fixture.remove() }
    let candidate = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    let lockFD = try fixture.lock(candidate)
    defer { _ = Darwin.close(lockFD) }
    defer { _ = testBSDFileLock(lockFD, LOCK_UN) }
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      managedStaleManifestGracePeriod: .milliseconds(100)
    )

    await #expect(throws: DaemonControlError.self) {
      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
    }
  }

  @Test("Managed quiescence preserves an external controller manifest selection")
  func managedQuiescencePreservesExternalManifestSelection() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "external", external: true)
    defer { fixture.remove() }
    let managed = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    try fixture.writeManifest(at: managed, endpoint: "http://127.0.0.1:65104")
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .external,
      sessionFactory: { _ in RecordingHarnessClient() }
    )
    let selectedManifest = controller.externalManifestLocator.manifestURL

    try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()

    #expect(controller.externalManifestLocator.manifestURL == selectedManifest)
  }

  @Test("Controller discovers a runtime lane created during quiescence")
  func controllerDiscoversRuntimeLaneCreatedDuringQuiescence() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "late-lane")
    defer { fixture.remove() }
    let client = RecordingHarnessClient()
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      sessionFactory: { _ in client }
    )
    let quiescence = Task {
      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
    }

    try await Task.sleep(for: .milliseconds(75))
    let candidate = fixture.runtimeLaneCandidate("appeared-late")
    try fixture.writeManifest(at: candidate, endpoint: "http://127.0.0.1:65105")
    try await quiescence.value

    #expect(client.lock.withLock { client.stopDaemonRequestCount } == 1)
  }

  @Test("Controller bounds all-root waits by one shared deadline")
  func controllerBoundsAllRootWaitsByOneSharedDeadline() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "shared-deadline")
    defer { fixture.remove() }
    var lockFDs: [Int32] = []
    defer {
      for fd in lockFDs {
        _ = testBSDFileLock(fd, LOCK_UN)
        _ = Darwin.close(fd)
      }
    }
    for lane in ["one", "two", "three"] {
      lockFDs.append(try fixture.lock(fixture.runtimeLaneCandidate(lane)))
    }
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      managedStaleManifestGracePeriod: .milliseconds(120)
    )
    let startedAt = ContinuousClock.now

    await #expect(throws: DaemonControlError.self) {
      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
    }

    #expect(ContinuousClock.now - startedAt < .milliseconds(300))
  }

  @Test("Controller falls back to a validated process signal")
  func controllerFallsBackToValidatedProcessSignal() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "signal-fallback")
    defer { fixture.remove() }
    let candidate = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    let pid: Int32 = 45_612
    try fixture.writeManifest(
      at: candidate,
      endpoint: "http://127.0.0.1:65106",
      pid: pid
    )
    let client = RecordingHarnessClient()
    client.stopDaemonError = ManagedDaemonQuiescenceTestError.stopFailed
    let signalRecorder = ManagedDaemonSignalRecorder()
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      sessionFactory: { _ in client },
      processLiveness: { requestedPID in
        #expect(requestedPID == pid)
        return .alive(
          executablePath: "/Applications/Harness Monitor.app/Contents/Resources/harness-daemon")
      },
      processSignal: { requestedPID, signal in
        signalRecorder.record(pid: requestedPID, signal: signal)
        return 0
      },
      managedDaemonProcessIdentityValidator: { requestedPID in
        requestedPID == pid
      }
    )

    try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()

    let recordedSignal = try #require(signalRecorder.value)
    #expect(recordedSignal.0 == pid)
    #expect(recordedSignal.1 == SIGTERM)
  }

  @Test("Controller recovers the endpoint from the candidate root")
  func controllerRecoversEndpointFromCandidateRoot() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "endpoint-recovery")
    defer { fixture.remove() }
    let candidate = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    try fixture.writeManifest(at: candidate, endpoint: "http://127.0.0.1:0")
    try fixture.writeEvents(
      at: candidate,
      endpoint: "http://127.0.0.1:65107"
    )
    let capturedEndpoint = ManagedDaemonEndpointRecorder()
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      sessionFactory: { connection in
        capturedEndpoint.record(connection.endpoint)
        return RecordingHarnessClient()
      }
    )

    try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()

    #expect(capturedEndpoint.value?.port == 65_107)
  }
}

private struct ManagedDaemonQuiescenceFixture {
  let homeDirectory: URL
  let environment: HarnessMonitorEnvironment

  init(name: String, external: Bool = false) throws {
    homeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-quiescence-\(name)-\(UUID().uuidString)", isDirectory: true)
    var values = [
      HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier
    ]
    if external {
      values[DaemonOwnership.environmentKey] = "1"
    }
    environment = HarnessMonitorEnvironment(values: values, homeDirectory: homeDirectory)
  }

  func remove() {
    try? FileManager.default.removeItem(at: homeDirectory)
  }

  func lock(_ candidate: ManagedDaemonRootCandidate) throws -> Int32 {
    try FileManager.default.createDirectory(
      at: candidate.rootURL,
      withIntermediateDirectories: true
    )
    let fd = Darwin.open(
      candidate.singletonLockURL.path,
      O_RDWR | O_CREAT | O_CLOEXEC,
      0o600
    )
    guard fd >= 0, testBSDFileLock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if fd >= 0 {
        _ = Darwin.close(fd)
      }
      throw ManagedDaemonQuiescenceTestError.lockFailed
    }
    return fd
  }

  func writeManifest(
    at candidate: ManagedDaemonRootCandidate,
    endpoint: String,
    pid: Int32 = getpid()
  ) throws {
    try FileManager.default.createDirectory(
      at: candidate.rootURL,
      withIntermediateDirectories: true
    )
    let tokenURL = candidate.rootURL.appendingPathComponent("auth-token")
    try writeTokenFixture(to: tokenURL)
    try writeExternalManifestFixture(
      at: candidate.manifestURL,
      pid: Int(pid),
      endpoint: endpoint,
      startedAt: "2026-08-09T20:00:00Z",
      tokenPath: tokenURL.path
    )
  }

  func runtimeLaneCandidate(_ lane: String) -> ManagedDaemonRootCandidate {
    let dataHome =
      homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(HarnessMonitorAppGroup.identifier, isDirectory: true)
      .appendingPathComponent(
        HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(lane, isDirectory: true)
    return ManagedDaemonRootCandidate(
      rootURL:
        dataHome
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("daemon", isDirectory: true)
        .appendingPathComponent(DaemonOwnership.managed.rawValue, isDirectory: true)
    )
  }

  func writeEvents(
    at candidate: ManagedDaemonRootCandidate,
    endpoint: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let event = DaemonAuditEventFixture(
      recordedAt: "2026-08-09T20:00:01Z",
      level: "info",
      message: "daemon listening on \(endpoint)"
    )
    let data = try encoder.encode(event)
    try data.write(to: candidate.rootURL.appendingPathComponent("events.jsonl"))
  }
}

private final class ManagedDaemonSignalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValue: (Int32, Int32)?

  var value: (Int32, Int32)? {
    lock.withLock { recordedValue }
  }

  func record(pid: Int32, signal: Int32) {
    lock.withLock {
      recordedValue = (pid, signal)
    }
  }
}

private final class ManagedDaemonEndpointRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValue: URL?

  var value: URL? {
    lock.withLock { recordedValue }
  }

  func record(_ endpoint: URL) {
    lock.withLock {
      recordedValue = endpoint
    }
  }
}

private actor ManagedDaemonQuiescenceCompletion {
  private(set) var isComplete = false

  func markComplete() {
    isComplete = true
  }
}

private enum ManagedDaemonQuiescenceTestError: Error {
  case lockFailed
  case stopFailed
}

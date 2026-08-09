import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed daemon quiescence", .serialized)
struct LegacyManagedDaemonQuiescenceTests {
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
    endpoint: String
  ) throws {
    try FileManager.default.createDirectory(
      at: candidate.rootURL,
      withIntermediateDirectories: true
    )
    let tokenURL = candidate.rootURL.appendingPathComponent("auth-token")
    try writeTokenFixture(to: tokenURL)
    try writeExternalManifestFixture(
      at: candidate.manifestURL,
      pid: Int(getpid()),
      endpoint: endpoint,
      startedAt: "2026-08-09T20:00:00Z",
      tokenPath: tokenURL.path
    )
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

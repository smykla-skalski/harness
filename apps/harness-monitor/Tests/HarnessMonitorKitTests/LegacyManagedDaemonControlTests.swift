import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed daemon control", .serialized)
struct LegacyManagedDaemonControlTests {
  @Test("Managed helper identity accepts isolated lanes and known legacy helpers")
  func managedHelperIdentityAcceptsIsolatedLanes() {
    #expect(
      DaemonController.isTrustedManagedHelperIdentifier(
        "Q498EB36N4.io.harnessmonitor.managed-service-fix-automation-6245e82a"
      )
    )
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

  @Test("Managed helper path accepts current and pre-migration bundle locations")
  func managedHelperPathAcceptsCurrentAndLegacyLocations() {
    #expect(
      DaemonController.isTrustedManagedHelperExecutablePath(
        "/Applications/Harness Monitor.app/Contents/Helpers/harness-daemon"
      )
    )
    #expect(
      DaemonController.isTrustedManagedHelperExecutablePath(
        "/Applications/Harness Monitor.app/Contents/Resources/harness-daemon"
      )
    )
    #expect(
      DaemonController.isTrustedManagedHelperExecutablePath(
        "/tmp/harness-daemon"
      ) == false
    )
    #expect(
      DaemonController.isTrustedManagedHelperExecutablePath(
        "/Applications/Harness Monitor.app/Contents/Resources/harness-daemon-copy"
      ) == false
    )
  }

  @Test("Controller falls back to a validated process signal")
  func controllerFallsBackToValidatedProcessSignal() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "signal-fallback")
    defer { fixture.remove() }
    let candidate = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    let pid: Int32 = 45_612
    let legacyHelperPath =
      "/Applications/Harness Monitor.app/Contents/Resources/harness-daemon"
    try fixture.writeManifest(
      at: candidate,
      endpoint: "http://127.0.0.1:65106",
      pid: pid,
      binaryStamp: DaemonBinaryStampFixture(
        helperPath: legacyHelperPath,
        deviceIdentifier: 1,
        inode: 2,
        fileSize: 3,
        modificationTimeIntervalSince1970: 4
      )
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
        return .alive(executablePath: legacyHelperPath)
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

  @Test("Controller bounds stalled daemon control by the shared deadline")
  func controllerBoundsStalledDaemonControlBySharedDeadline() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "stalled-control")
    defer { fixture.remove() }
    let candidate = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    let pid: Int32 = 45_613
    try fixture.writeManifest(
      at: candidate,
      endpoint: "http://127.0.0.1:65108",
      pid: pid
    )
    let client = RecordingHarnessClient()
    client.stopDaemonDelay = .seconds(5)
    let signalRecorder = ManagedDaemonSignalRecorder()
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      sessionFactory: { _ in client },
      managedStaleManifestGracePeriod: .milliseconds(100),
      processLiveness: { _ in
        .alive(
          executablePath: "/Applications/Harness Monitor.app/Contents/Resources/harness-daemon")
      },
      processSignal: { requestedPID, signal in
        signalRecorder.record(pid: requestedPID, signal: signal)
        return 0
      },
      managedDaemonProcessIdentityValidator: { _ in true }
    )
    let startedAt = ContinuousClock.now

    await #expect(throws: DaemonControlError.self) {
      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
    }

    #expect(ContinuousClock.now - startedAt < .milliseconds(300))
    let recordedSignal = try #require(signalRecorder.value)
    #expect(recordedSignal.0 == pid)
    #expect(recordedSignal.1 == SIGTERM)
  }

  @Test("Cancellation still signals the validated managed daemon")
  func cancellationStillSignalsValidatedManagedDaemon() async throws {
    let fixture = try ManagedDaemonQuiescenceFixture(name: "cancelled-control")
    defer { fixture.remove() }
    let candidate = try #require(
      HarnessMonitorPaths.managedDaemonRootCandidates(using: fixture.environment).first
    )
    let pid: Int32 = 45_614
    try fixture.writeManifest(
      at: candidate,
      endpoint: "http://127.0.0.1:65109",
      pid: pid
    )
    let client = RecordingHarnessClient()
    client.stopDaemonDelay = .seconds(5)
    let signalRecorder = ManagedDaemonSignalRecorder()
    let controller = DaemonController(
      environment: fixture.environment,
      ownership: .managed,
      sessionFactory: { _ in client },
      processLiveness: { _ in
        .alive(
          executablePath: "/Applications/Harness Monitor.app/Contents/Resources/harness-daemon")
      },
      processSignal: { requestedPID, signal in
        signalRecorder.record(pid: requestedPID, signal: signal)
        return 0
      },
      managedDaemonProcessIdentityValidator: { _ in true }
    )
    let quiescence = Task {
      try await controller.quiesceManagedDaemonsAfterLegacyCleanupFailure()
    }
    try await Task.sleep(for: .milliseconds(50))
    quiescence.cancel()

    await #expect(throws: CancellationError.self) {
      try await quiescence.value
    }
    let recordedSignal = try #require(signalRecorder.value)
    #expect(recordedSignal.0 == pid)
    #expect(recordedSignal.1 == SIGTERM)
  }
}

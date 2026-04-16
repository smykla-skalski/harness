import Foundation
import Testing

@testable import HarnessMonitorKit

extension DaemonControllerTests {
  @Test("awaitManifestWarmUp reports external offline when no manifest appears")
  func awaitManifestWarmUpReportsExternalOfflineWhenManifestMissing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("daemon-controller-tests-\(UUID().uuidString)", isDirectory: true)
    let daemonHome = root.appendingPathComponent("data-home", isDirectory: true)
    try FileManager.default.createDirectory(at: daemonHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonHome.path],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )
    let controller = DaemonController(
      environment: environment,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      ownership: .external
    )

    do {
      _ = try await controller.awaitManifestWarmUp(timeout: .milliseconds(50))
      Issue.record("Expected externalDaemonOffline")
    } catch let error as DaemonControlError {
      guard case .externalDaemonOffline(let manifestPath) = error else {
        Issue.record("Expected externalDaemonOffline, got \(error)")
        return
      }
      #expect(manifestPath == HarnessMonitorPaths.manifestURL(using: environment).path)
    } catch {
      Issue.record("Expected DaemonControlError, got \(error)")
    }
  }

  @Test("awaitManifestWarmUp reports manifestMissing when no managed manifest appears")
  func awaitManifestWarmUpReportsManagedManifestMissing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("daemon-controller-tests-\(UUID().uuidString)", isDirectory: true)
    let daemonHome = root.appendingPathComponent("data-home", isDirectory: true)
    try FileManager.default.createDirectory(at: daemonHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonHome.path],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )
    let controller = DaemonController(
      environment: environment,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      ownership: .managed
    )

    await #expect(throws: DaemonControlError.manifestMissing) {
      _ = try await controller.awaitManifestWarmUp(timeout: .milliseconds(50))
    }
  }

  @Test("bootstrapClient rejects managed manifests with non-loopback endpoints")
  func bootstrapClientRejectsNonLoopbackManagedEndpoint() async throws {
    try await withTempDaemonFixture(
      pid: 1_234,
      endpoint: "http://example.com:65534"
    ) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        sessionFactory: { _ in PreviewHarnessClient() }
      )

      do {
        _ = try await controller.bootstrapClient()
        Issue.record("Expected invalidManifest")
      } catch let error as DaemonControlError {
        guard case .invalidManifest(let reason) = error else {
          Issue.record("Expected invalidManifest, got \(error)")
          return
        }
        #expect(reason.contains("loopback"))
      } catch {
        Issue.record("Expected DaemonControlError, got \(error)")
      }
    }
  }

  @Test("bootstrapClient rejects symlinked token paths")
  func bootstrapClientRejectsSymlinkedTokenPath() async throws {
    try await withTempDaemonFixture(
      pid: 1_234,
      tokenPathFactory: { daemonRoot in
        let outsideToken = daemonRoot.deletingLastPathComponent()
          .appendingPathComponent("outside-auth-token")
        try writeTokenFixture(to: outsideToken)
        let symlinkURL = daemonRoot.appendingPathComponent("auth-token-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideToken)
        return symlinkURL
      },
      perform: { environment in
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
          ownership: .managed,
          sessionFactory: { _ in PreviewHarnessClient() }
        )

        do {
          _ = try await controller.bootstrapClient()
          Issue.record("Expected invalidManifest")
        } catch let error as DaemonControlError {
          guard case .invalidManifest(let reason) = error else {
            Issue.record("Expected invalidManifest, got \(error)")
            return
          }
          #expect(reason.contains("symlink"))
        } catch {
          Issue.record("Expected DaemonControlError, got \(error)")
        }
      }
    )
  }

  @Test("bootstrapClient rejects group-readable token files")
  func bootstrapClientRejectsPermissiveTokenPermissions() async throws {
    try await withTempDaemonFixture(
      pid: 1_234,
      tokenPathFactory: { daemonRoot in
        let tokenURL = daemonRoot.appendingPathComponent("auth-token")
        try writeTokenFixture(to: tokenURL, permissions: 0o644)
        return tokenURL
      },
      perform: { environment in
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
          ownership: .managed,
          sessionFactory: { _ in PreviewHarnessClient() }
        )

        do {
          _ = try await controller.bootstrapClient()
          Issue.record("Expected invalidManifest")
        } catch let error as DaemonControlError {
          guard case .invalidManifest(let reason) = error else {
            Issue.record("Expected invalidManifest, got \(error)")
            return
          }
          #expect(reason.contains("permissions"))
        } catch {
          Issue.record("Expected DaemonControlError, got \(error)")
        }
      }
    )
  }

  @Test("Installing launch agent registers the bundled service")
  func installingLaunchAgentRegistersBundledService() async throws {
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let controller = DaemonController(launchAgentManager: manager)

    let result = try await controller.installLaunchAgent()

    #expect(result == "launch agent installed")
    #expect(manager.registerCallCount == 1)
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.state == .enabled)
  }

  @Test("Removing launch agent unregisters enabled service")
  func removingLaunchAgentUnregistersEnabledService() async throws {
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(launchAgentManager: manager)

    let result = try await controller.removeLaunchAgent()

    #expect(result == "launch agent removed")
    #expect(manager.registerCallCount == 0)
    #expect(manager.unregisterCallCount == 1)
    #expect(manager.state == .notRegistered)
  }

  @Test("Approval-required launch agent does not re-register")
  func approvalRequiredLaunchAgentDoesNotRegister() async throws {
    let manager = RecordingLaunchAgentManager(state: .requiresApproval)
    let controller = DaemonController(launchAgentManager: manager)

    await #expect(throws: DaemonControlError.self) {
      _ = try await controller.installLaunchAgent()
    }
    #expect(manager.registerCallCount == 0)
  }

  @Test("registerLaunchAgent returns enabled after registering notRegistered agent")
  func registerLaunchAgentReturnsEnabledState() async throws {
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let controller = DaemonController(launchAgentManager: manager)

    let state = try await controller.registerLaunchAgent()

    #expect(state == .enabled)
    #expect(manager.registerCallCount == 1)
  }

  @Test("registerLaunchAgent surfaces requiresApproval when SMAppService needs consent")
  func registerLaunchAgentSurfacesApprovalRequired() async throws {
    let manager = RecordingLaunchAgentManager(
      state: .notRegistered,
      registerResult: .requiresApproval
    )
    let controller = DaemonController(launchAgentManager: manager)

    let state = try await controller.registerLaunchAgent()

    #expect(state == .requiresApproval)
    #expect(manager.registerCallCount == 1)
  }

  @Test("awaitLaunchAgentState throws daemonDidNotStart when state never matches")
  func awaitLaunchAgentStateTimesOut() async throws {
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let controller = DaemonController(launchAgentManager: manager)

    await #expect(throws: DaemonControlError.daemonDidNotStart) {
      try await controller.awaitLaunchAgentState(
        .enabled,
        timeout: .milliseconds(50)
      )
    }
  }

  @Test("awaitLaunchAgentState returns immediately when state already matches")
  func awaitLaunchAgentStateReturnsWhenReady() async throws {
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(launchAgentManager: manager)

    try await controller.awaitLaunchAgentState(
      .enabled,
      timeout: .milliseconds(50)
    )
  }

  @Test("launchAgentSnapshot mirrors current registration state")
  func launchAgentSnapshotMirrorsRegistrationState() async throws {
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(launchAgentManager: manager)

    let enabledSnapshot = await controller.launchAgentSnapshot()
    #expect(enabledSnapshot.installed == true)
    #expect(enabledSnapshot.loaded == true)

    try manager.unregister()

    let offlineSnapshot = await controller.launchAgentSnapshot()
    #expect(offlineSnapshot.installed == false)
    #expect(offlineSnapshot.loaded == false)
  }
}

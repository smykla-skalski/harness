import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

private let managedLaunchAgentHelperPathFixture =
  "/Users/example/Library/Developer/Xcode/DerivedData/HarnessMonitor/Build/Products/Debug/"
  + "Harness Monitor.app/Contents/Helpers/harness"

@Suite("Daemon controller managed launch-agent warm-up")
struct DaemonControllerManagedLaunchAgentWarmUpTests {
  @Test(
    "awaitManifestWarmUp refreshes the managed launch agent before probing when the bundled helper changed"
  )
  func awaitManifestWarmUpRefreshesManagedLaunchAgentBeforeProbingWhenBundledHelperChanged()
    async throws
  {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let client = PreviewHarnessClient()
      let manifestRewritePID = UInt32(getpid())
      let liveEndpoint = "http://127.0.0.1:65533"
      try writeManagedLaunchAgentBundleStampFixture(
        ManagedLaunchAgentBundleStampFixture(
          helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness",
          deviceIdentifier: 41,
          inode: 84,
          fileSize: 16_384,
          modificationTimeIntervalSince1970: 1_713_000_000
        ),
        environment: environment
      )
      let manager = HookedLaunchAgentManager(
        state: .enabled,
        onRegister: {
          try rewriteTempDaemonFixtureManifest(
            environment: environment,
            pid: manifestRewritePID,
            endpoint: liveEndpoint,
            startedAt: "2026-04-14T13:22:13Z"
          )
        }
      )
      let probedEndpoints = EndpointProbeRecorder()
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: manager,
        ownership: .managed,
        sessionFactory: { _ in client },
        endpointProbe: { endpoint in
          await probedEndpoints.record(endpoint.absoluteString)
          return endpoint.absoluteString == liveEndpoint
        },
        managedLaunchAgentCurrentBundleStamp: {
          ManagedLaunchAgentBundleStamp(
            helperPath: managedLaunchAgentHelperPathFixture,
            deviceIdentifier: 99,
            inode: 128,
            fileSize: 32_768,
            modificationTimeIntervalSince1970: 1_714_000_000
          )
        }
      )

      let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))

      #expect(bootstrappedClient as AnyObject === client as AnyObject)
      #expect(manager.unregisterCallCount == 1)
      #expect(manager.registerCallCount == 1)
      #expect(await probedEndpoints.values() == [liveEndpoint])
    }
  }

  @Test(
    "awaitManifestWarmUp waits for a replacement manifest after refreshing a changed bundled helper"
  )
  func awaitManifestWarmUpWaitsForReplacementManifestAfterBundledHelperRefresh()
    async throws
  {
    let currentStamp = ManagedLaunchAgentBundleStampFixture(
      helperPath: managedLaunchAgentHelperPathFixture,
      deviceIdentifier: 99,
      inode: 128,
      fileSize: 32_768,
      modificationTimeIntervalSince1970: 1_714_000_000
    )
    let stalePersistedStamp = ManagedLaunchAgentBundleStampFixture(
      helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness",
      deviceIdentifier: 41,
      inode: 84,
      fileSize: 16_384,
      modificationTimeIntervalSince1970: 1_713_000_000
    )
    let staleEndpoint = "http://127.0.0.1:65534"
    let liveEndpoint = "http://127.0.0.1:65532"

    try await withSignalIgnoringSleepProcessPID { livePID in
      try await withTempDaemonFixture(pid: 999_999, endpoint: staleEndpoint) { environment in
        let client = PreviewHarnessClient()
        try writeManagedLaunchAgentBundleStampFixture(stalePersistedStamp, environment: environment)
        let manager = RecordingLaunchAgentManager(state: .enabled)
        let probedEndpoints = EndpointProbeRecorder()
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: manager,
          ownership: .managed,
          sessionFactory: { _ in client },
          endpointProbe: { endpoint in
            await probedEndpoints.record(endpoint.absoluteString)
            return endpoint.absoluteString == liveEndpoint
          },
          managedLaunchAgentCurrentBundleStamp: {
            ManagedLaunchAgentBundleStamp(
              helperPath: currentStamp.helperPath,
              deviceIdentifier: currentStamp.deviceIdentifier,
              inode: currentStamp.inode,
              fileSize: currentStamp.fileSize,
              modificationTimeIntervalSince1970: currentStamp.modificationTimeIntervalSince1970
            )
          }
        )

        Task.detached {
          try? await Task.sleep(for: .milliseconds(150))
          try? rewriteTempDaemonFixtureManifest(
            environment: environment,
            pid: livePID,
            endpoint: liveEndpoint,
            startedAt: "2026-04-14T13:22:13Z"
          )
        }

        let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))

        #expect(bootstrappedClient as AnyObject === client as AnyObject)
        #expect(manager.unregisterCallCount == 1)
        #expect(manager.registerCallCount == 1)
        #expect(await probedEndpoints.values() == [staleEndpoint, liveEndpoint])
      }
    }
  }

  @Test(
    "awaitManifestWarmUp refreshes the managed launch agent before trusting a live manifest from a replaced helper"
  )
  func awaitManifestWarmUpRefreshesManagedLaunchAgentBeforeTrustingMismatchedLiveHelperIdentity()
    async throws
  {
    let currentStamp = ManagedLaunchAgentBundleStampFixture(
      helperPath: managedLaunchAgentHelperPathFixture,
      deviceIdentifier: 99,
      inode: 128,
      fileSize: 32_768,
      modificationTimeIntervalSince1970: 1_714_000_000
    )
    let staleManifestStamp = DaemonBinaryStampFixture(
      helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness",
      deviceIdentifier: 41,
      inode: 84,
      fileSize: 16_384,
      modificationTimeIntervalSince1970: 1_713_000_000
    )
    let liveEndpoint = "http://127.0.0.1:65533"

    try await withSignalIgnoringSleepProcessPID { livePID in
      try await withTempDaemonFixture(
        pid: livePID,
        endpoint: liveEndpoint,
        binaryStamp: staleManifestStamp
      ) { environment in
        let client = PreviewHarnessClient()
        try writeManagedLaunchAgentBundleStampFixture(currentStamp, environment: environment)
        let manager = HookedLaunchAgentManager(
          state: .enabled,
          onRegister: {
            try rewriteTempDaemonFixtureManifest(
              environment: environment,
              pid: livePID,
              endpoint: liveEndpoint,
              startedAt: "2026-04-14T13:22:13Z",
              binaryStamp: DaemonBinaryStampFixture(
                helperPath: currentStamp.helperPath,
                deviceIdentifier: currentStamp.deviceIdentifier,
                inode: currentStamp.inode,
                fileSize: currentStamp.fileSize,
                modificationTimeIntervalSince1970: currentStamp.modificationTimeIntervalSince1970
              )
            )
          }
        )
        let probedEndpoints = EndpointProbeRecorder()
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: manager,
          ownership: .managed,
          sessionFactory: { _ in client },
          endpointProbe: { endpoint in
            await probedEndpoints.record(endpoint.absoluteString)
            return endpoint.absoluteString == liveEndpoint
          },
          managedLaunchAgentCurrentBundleStamp: {
            ManagedLaunchAgentBundleStamp(
              helperPath: currentStamp.helperPath,
              deviceIdentifier: currentStamp.deviceIdentifier,
              inode: currentStamp.inode,
              fileSize: currentStamp.fileSize,
              modificationTimeIntervalSince1970: currentStamp.modificationTimeIntervalSince1970
            )
          }
        )

        let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))

        #expect(bootstrappedClient as AnyObject === client as AnyObject)
        #expect(manager.unregisterCallCount == 1)
        #expect(manager.registerCallCount == 1)
        #expect(await probedEndpoints.values() == [liveEndpoint])
      }
    }
  }

  @Test(
    "awaitManifestWarmUp refreshes the managed launch agent and waits for version-mismatch manifest rewrite"
  )
  func awaitManifestWarmUpRefreshesManagedLaunchAgentAndWaitsForVersionMismatchRewrite()
    async throws
  {
    let currentStamp = ManagedLaunchAgentBundleStampFixture(
      helperPath: managedLaunchAgentHelperPathFixture,
      deviceIdentifier: 99,
      inode: 128,
      fileSize: 32_768,
      modificationTimeIntervalSince1970: 1_714_000_000
    )
    let staleEndpoint = "http://127.0.0.1:65534"
    let liveEndpoint = "http://127.0.0.1:65533"
    let expectedVersion = "23.1.1"

    try await withSignalIgnoringSleepProcessPID { stalePID in
      try await withTempDaemonFixture(
        pid: stalePID,
        version: "23.1.0",
        endpoint: staleEndpoint
      ) { environment in
        let client = PreviewHarnessClient()
        try writeManagedLaunchAgentBundleStampFixture(currentStamp, environment: environment)
        let manager = HookedLaunchAgentManager(
          state: .enabled,
          onRegister: {
            Task.detached {
              try? await Task.sleep(for: .milliseconds(150))
              try? rewriteTempDaemonFixtureManifest(
                environment: environment,
                pid: UInt32(getpid()),
                version: expectedVersion,
                endpoint: liveEndpoint,
                startedAt: "2026-04-17T11:03:00Z",
                binaryStamp: DaemonBinaryStampFixture(
                  helperPath: currentStamp.helperPath,
                  deviceIdentifier: currentStamp.deviceIdentifier,
                  inode: currentStamp.inode,
                  fileSize: currentStamp.fileSize,
                  modificationTimeIntervalSince1970:
                    currentStamp.modificationTimeIntervalSince1970
                )
              )
            }
          }
        )
        let probedEndpoints = EndpointProbeRecorder()
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: manager,
          ownership: .managed,
          sessionFactory: { _ in client },
          endpointProbe: { endpoint in
            await probedEndpoints.record(endpoint.absoluteString)
            return endpoint.absoluteString == liveEndpoint
          },
          expectedManagedDaemonVersion: { expectedVersion },
          managedLaunchAgentCurrentBundleStamp: {
            ManagedLaunchAgentBundleStamp(
              helperPath: currentStamp.helperPath,
              deviceIdentifier: currentStamp.deviceIdentifier,
              inode: currentStamp.inode,
              fileSize: currentStamp.fileSize,
              modificationTimeIntervalSince1970:
                currentStamp.modificationTimeIntervalSince1970
            )
          }
        )

        let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))

        #expect(bootstrappedClient as AnyObject === client as AnyObject)
        #expect(manager.unregisterCallCount == 1)
        #expect(manager.registerCallCount == 1)
        #expect(await probedEndpoints.values() == [liveEndpoint])
      }
    }
  }
}

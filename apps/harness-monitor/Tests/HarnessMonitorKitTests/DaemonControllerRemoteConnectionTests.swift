import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon controller remote connections")
struct DaemonControllerRemoteConnectionTests {
  @Test("Remote profile resolves without a local manifest")
  func remoteProfileBypassesLocalManifest() async throws {
    let fixture = try RemoteControllerFixture()
    let recorder = RemoteConnectionRecorder()
    let controller = DaemonController(
      environment: fixture.environment,
      transportPreference: .http,
      launchAgentManager: fixture.launchAgent,
      remoteConnectionSource: fixture.source,
      sessionFactory: { connection in
        recorder.record(connection)
        return PreviewHarnessClient()
      }
    )

    let client = try await controller.bootstrapClient()

    #expect(recorder.connections == [fixture.connection])
    await client.shutdown()
  }

  @Test("Corrupt remote profile metadata falls back to the local manifest")
  func corruptRemoteProfileFallsBackToLocalManifest() async throws {
    let pid = UInt32(ProcessInfo.processInfo.processIdentifier)
    try await withTempDaemonFixture(pid: pid) { environment in
      let controller = DaemonController(
        environment: environment,
        transportPreference: .http,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        remoteConnectionSource: CorruptThenClearedRemoteDaemonConnectionSource()
      )

      let connection = try controller.loadConnection()

      #expect(connection.endpoint.absoluteString == "http://127.0.0.1:65534")
      #expect(connection.token == "test-token")
      #expect(connection.source == .local)
    }
  }

  @Test("Remote WebSocket bootstrap performs pinned HTTP auth preflight")
  func remoteWebSocketPerformsHTTPPreflight() async throws {
    let fixture = try RemoteControllerFixture()
    let httpRecorder = RemoteConnectionRecorder()
    let webSocketRecorder = RemoteConnectionRecorder()
    let controller = DaemonController(
      environment: fixture.environment,
      transportPreference: .webSocket,
      launchAgentManager: fixture.launchAgent,
      remoteConnectionSource: fixture.source,
      sessionFactory: { connection in
        httpRecorder.record(connection)
        return PreviewHarnessClient()
      },
      webSocketBootstrapper: { connection in
        webSocketRecorder.record(connection)
        return PreviewHarnessClient()
      }
    )

    let client = try await controller.bootstrapClient()

    #expect(httpRecorder.connections == [fixture.connection])
    #expect(webSocketRecorder.connections == [fixture.connection])
    await client.shutdown()
  }

  @Test("Remote 401 marks the active profile revoked")
  func unauthorizedRemoteBootstrapMarksProfileRevoked() async throws {
    let fixture = try RemoteControllerFixture()
    let controller = DaemonController(
      environment: fixture.environment,
      transportPreference: .http,
      launchAgentManager: fixture.launchAgent,
      remoteConnectionSource: fixture.source,
      sessionFactory: { _ in
        FailingHarnessClient(
          error: HarnessMonitorAPIError.server(code: 401, message: "unauthorized")
        )
      }
    )

    await #expect(throws: HarnessMonitorAPIError.self) {
      _ = try await controller.bootstrapClient()
    }

    #expect(fixture.source.revokedProfileIDs == [fixture.profile.id])
  }

  @Test("Remote mode rejects local launch agent installation")
  func remoteModeRejectsLocalLaunchAgentInstall() async throws {
    let fixture = try RemoteControllerFixture()
    let controller = DaemonController(
      environment: fixture.environment,
      launchAgentManager: fixture.launchAgent,
      remoteConnectionSource: fixture.source
    )

    await #expect(throws: DaemonControlError.self) {
      _ = try await controller.installLaunchAgent()
    }

    #expect(fixture.launchAgent.registerCallCount == 0)
    #expect(fixture.launchAgent.unregisterCallCount == 0)
  }

  @Test("Corrupt remote metadata still allows local launch agent controls")
  func corruptRemoteMetadataAllowsLocalLaunchAgentControl() async throws {
    let launchAgent = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(
      launchAgentManager: launchAgent,
      remoteConnectionSource: CorruptThenClearedRemoteDaemonConnectionSource()
    )

    let status = try await controller.installLaunchAgent()

    #expect(status == "launch agent already installed")
    #expect(launchAgent.unregisterCallCount == 0)
  }

  @Test("Corrupt remote metadata still allows stopping the local daemon")
  func corruptRemoteMetadataAllowsLocalStop() async throws {
    let launchAgent = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(
      launchAgentManager: launchAgent,
      remoteConnectionSource: CorruptThenClearedRemoteDaemonConnectionSource()
    )

    let status = try await controller.stopDaemon()

    #expect(status == "stopped")
    #expect(launchAgent.unregisterCallCount == 1)
  }

  @Test("Remote stop closes its temporary authenticated client")
  func remoteStopShutsDownClient() async throws {
    let fixture = try RemoteControllerFixture()
    let client = RecordingHarnessClient()
    let controller = DaemonController(
      environment: fixture.environment,
      transportPreference: .http,
      launchAgentManager: fixture.launchAgent,
      remoteConnectionSource: fixture.source,
      sessionFactory: { _ in client }
    )

    let status = try await controller.stopDaemon()

    #expect(status == "stopping")
    #expect(client.shutdownCallCount() == 1)
  }
}

private struct RemoteControllerFixture {
  let environment: HarnessMonitorEnvironment
  let profile: RemoteDaemonProfile
  let connection: HarnessMonitorConnection
  let source: RecordingRemoteDaemonConnectionSource
  let launchAgent: RecordingLaunchAgentManager

  init() throws {
    let profile = try remoteProfileFixture()
    let connection = HarnessMonitorConnection(
      endpoint: profile.endpoint,
      token: "opaque-bearer-secret",
      serverTrust: .spkiSHA256(profile.serverSPKISHA256),
      source: .remote(profileID: profile.id)
    )
    self.environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: FileManager.default.temporaryDirectory
    )
    self.profile = profile
    self.connection = connection
    self.source = RecordingRemoteDaemonConnectionSource(
      profile: profile,
      connection: connection
    )
    self.launchAgent = RecordingLaunchAgentManager(state: .notRegistered)
  }
}

private final class RecordingRemoteDaemonConnectionSource:
  RemoteDaemonConnectionSourcing, @unchecked Sendable
{
  private let lock = NSLock()
  private let profile: RemoteDaemonProfile
  private let connection: HarnessMonitorConnection
  private var revokedIDs: [UUID] = []

  init(profile: RemoteDaemonProfile, connection: HarnessMonitorConnection) {
    self.profile = profile
    self.connection = connection
  }

  var revokedProfileIDs: [UUID] {
    lock.withLock { revokedIDs }
  }

  func activeConnection() throws -> HarnessMonitorConnection? {
    connection
  }

  func activeProfile() throws -> RemoteDaemonProfile? {
    profile
  }

  func markRevoked(profileID: UUID, at date: Date) throws {
    lock.withLock { revokedIDs.append(profileID) }
  }
}

private final class CorruptThenClearedRemoteDaemonConnectionSource:
  RemoteDaemonConnectionSourcing, @unchecked Sendable
{
  private let lock = NSLock()
  private var isCleared = false

  func activeConnection() throws -> HarnessMonitorConnection? {
    let shouldThrow = lock.withLock {
      defer { isCleared = true }
      return !isCleared
    }
    if shouldThrow {
      throw RemoteDaemonProfileError.invalidStoredProfiles
    }
    return nil
  }

  func activeProfile() throws -> RemoteDaemonProfile? {
    throw RemoteDaemonProfileError.invalidStoredProfiles
  }

  func markRevoked(profileID: UUID, at date: Date) throws {}
}

private final class RemoteConnectionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedConnections: [HarnessMonitorConnection] = []

  var connections: [HarnessMonitorConnection] {
    lock.withLock { recordedConnections }
  }

  func record(_ connection: HarnessMonitorConnection) {
    lock.withLock { recordedConnections.append(connection) }
  }
}

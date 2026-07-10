import Foundation

extension DaemonController {
  func bootstrapRemoteConnection(
    _ connection: HarnessMonitorConnection
  ) async throws -> any HarnessMonitorClientProtocol {
    let httpClient = sessionFactory(connection)
    do {
      _ = try await httpClient.health()
    } catch {
      await httpClient.shutdown()
      throw error
    }
    if transportPreference == .http {
      return httpClient
    }
    if transportPreference == .auto {
      switch await bootstrapAutoTransport(connection: connection) {
      case .upgraded(let webSocketClient):
        await httpClient.shutdown()
        return webSocketClient
      case .unavailable, .timedOut:
        return httpClient
      }
    }
    if let webSocketClient = await webSocketBootstrapper(connection) {
      await httpClient.shutdown()
      return webSocketClient
    }
    await httpClient.shutdown()
    throw DaemonControlError.commandFailed("WebSocket connection failed")
  }

  func handleRemoteAuthorizationFailure(
    _ error: any Error,
    connection: HarnessMonitorConnection
  ) {
    guard
      case .remote(let profileID) = connection.source,
      let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError,
      code == 401
    else {
      return
    }
    do {
      try remoteConnectionSource.markRevoked(profileID: profileID, at: .now)
    } catch {
      HarnessMonitorLogger.lifecycle.error(
        "Failed to mark remote daemon profile revoked: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func requireLocalDaemonControl(_ action: String) throws {
    let remoteProfile = try loadRemoteStateRecoveringCorruptMetadata {
      try remoteConnectionSource.activeProfile()
    }
    guard remoteProfile == nil else {
      throw DaemonControlError.commandFailed(
        "\(action) is unavailable while a remote daemon profile is active"
      )
    }
  }

  func loadRemoteStateRecoveringCorruptMetadata<Value>(
    _ load: () throws -> Value?
  ) throws -> Value? {
    do {
      return try load()
    } catch {
      guard error as? RemoteDaemonProfileError == .invalidStoredProfiles else {
        throw error
      }
      HarnessMonitorLogger.lifecycle.notice(
        "Discarded unreadable remote daemon profile metadata; using local daemon state"
      )
      return nil
    }
  }

  func requestDaemonStop(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> String {
    do {
      let response = try await client.stopDaemon()
      await client.shutdown()
      return response.status
    } catch {
      await client.shutdown()
      throw error
    }
  }
}

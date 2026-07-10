import Foundation
import HarnessMonitorCore

extension MobileRemoteDaemonSyncClient {
  public func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandSubmission {
    guard supportsCommands else {
      throw MobileRemoteDaemonSyncError.commandsUnavailable
    }
    guard command.stationID == stationID, command.target.stationID == stationID else {
      throw MobileRemoteDaemonSyncError.stationMismatch
    }
    guard command.expiresAt > now else {
      throw MobileRemoteDaemonSyncError.commandExpired
    }

    let reviewTarget = try await resolvedReviewTarget(for: command)
    let agentKind = try await resolvedAgentKind(for: command)
    let route = try MobileRemoteDaemonCommandRequestBuilder.make(
      command: command,
      agentKind: agentKind,
      clientID: access.clientID,
      reviewTarget: reviewTarget
    )
    var request = try authenticatedRequest(path: route.path, method: route.method)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body = route.body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (_, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    try validate(response)
    return succeededSubmission(
      command,
      currentRevision: currentRevision,
      now: now,
      message: route.successMessage
    )
  }

  public func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  func authenticatedRequest(path: String, method: String) throws -> URLRequest {
    guard
      var components = URLComponents(
        url: access.endpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      throw MobileRemoteDaemonSyncError.invalidCommand("invalid remote endpoint")
    }
    components.percentEncodedPath = path
    guard let url = components.url else {
      throw MobileRemoteDaemonSyncError.invalidCommand("invalid remote command path")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(access.bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(
      access.clientID,
      forHTTPHeaderField: RemoteDaemonAuthentication.clientIDHeader
    )
    return request
  }

  private func resolvedAgentKind(for command: MobileCommandRecord) async throws -> String? {
    guard [.agentStop, .agentPrompt].contains(command.kind) else {
      return nil
    }
    let agentID = try command.remoteRequiredAgentID()
    var request = try authenticatedRequest(
      path: "/v1/managed-agents/\(try agentID.remotePathComponent())",
      method: "GET"
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    try validate(response)
    return try JSONDecoder().decode(MobileRemoteDaemonAgentKindResponse.self, from: data).kind
  }

  private func succeededSubmission(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date,
    message: String
  ) -> MobileCommandSubmission {
    var command = command
    command.status = .succeeded
    command.updatedAt = now
    command.receipt = MobileCommandReceipt(
      commandID: command.id,
      stationID: command.stationID,
      status: .succeeded,
      message: message,
      receivedAt: now,
      completedAt: now,
      executionRevision: currentRevision
    )
    return MobileCommandSubmission(command: command, disposition: .completed)
  }
}

private struct MobileRemoteDaemonAgentKindResponse: Decodable {
  let kind: String
}

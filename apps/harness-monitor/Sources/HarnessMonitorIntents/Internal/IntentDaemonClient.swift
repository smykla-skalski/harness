import Foundation
import HarnessMonitorKit

public actor IntentDaemonClient {
  public let transport: WebSocketTransport

  public init(connection: HarnessMonitorConnection) {
    self.transport = WebSocketTransport(connection: connection)
  }

  public static func resolveFromEnvironment(
    environment: HarnessMonitorEnvironment = .current
  ) throws -> IntentDaemonClient {
    let connection = try IntentConnectionResolver.resolve(environment: environment)
    return IntentDaemonClient(connection: connection)
  }
}

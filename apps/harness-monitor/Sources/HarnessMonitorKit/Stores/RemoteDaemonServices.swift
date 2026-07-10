public struct RemoteDaemonServices: Sendable {
  public let connectionSource: any RemoteDaemonConnectionSourcing
  public let profileCoordinator: RemoteDaemonProfileCoordinator

  public init(
    connectionSource: any RemoteDaemonConnectionSourcing,
    profileCoordinator: RemoteDaemonProfileCoordinator
  ) {
    self.connectionSource = connectionSource
    self.profileCoordinator = profileCoordinator
  }
}

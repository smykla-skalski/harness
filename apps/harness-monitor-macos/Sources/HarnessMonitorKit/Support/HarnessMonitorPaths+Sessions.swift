import Foundation

extension HarnessMonitorPaths {
  public static func sessionsRoot(using env: HarnessMonitorEnvironment = .current) -> URL {
    harnessRoot(using: env).appendingPathComponent("sessions", isDirectory: true)
  }

  public static func sessionRoot(
    projectName: String,
    sessionId: String,
    using env: HarnessMonitorEnvironment = .current
  ) -> URL {
    sessionsRoot(using: env)
      .appendingPathComponent(projectName, isDirectory: true)
      .appendingPathComponent(sessionId, isDirectory: true)
  }

  public static func sessionWorktree(
    projectName: String,
    sessionId: String,
    using env: HarnessMonitorEnvironment = .current
  ) -> URL {
    sessionRoot(projectName: projectName, sessionId: sessionId, using: env)
      .appendingPathComponent("workspace", isDirectory: true)
  }

  public static func sessionShared(
    projectName: String,
    sessionId: String,
    using env: HarnessMonitorEnvironment = .current
  ) -> URL {
    sessionRoot(projectName: projectName, sessionId: sessionId, using: env)
      .appendingPathComponent("memory", isDirectory: true)
  }

  public static func socketDirectory(using env: HarnessMonitorEnvironment = .current) -> URL {
    let groupID = HarnessMonitorAppGroup.identifier
    let container = nativeAppGroupContainerURL(identifier: groupID, using: env)
    guard let group = container else {
      return harnessRoot(using: env).appendingPathComponent("sock", isDirectory: true)
    }
    return group.appendingPathComponent("sock", isDirectory: true)
  }
}

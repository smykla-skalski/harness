import Foundation

public struct SettingsNavigationRequest: Equatable, Sendable {
  public let id: UUID
  public let target: SettingsNavigationTarget

  public init(id: UUID = UUID(), target: SettingsNavigationTarget) {
    self.id = id
    self.target = target
  }
}

public enum SettingsNavigationTarget: Equatable, Hashable, Sendable {
  case section(SettingsSection)
  case taskBoard(SettingsTaskBoardAnchor)

  public var section: SettingsSection {
    switch self {
    case .section(let section):
      return section
    case .taskBoard:
      return .taskBoard
    }
  }
}

public enum SettingsTaskBoardAnchor: String, Equatable, Hashable, Sendable {
  case githubProject
  case githubInbox
}

extension SettingsNavigationRequest {
  var taskBoardAnchor: SettingsTaskBoardAnchor? {
    switch target {
    case .section:
      return nil
    case .taskBoard(let anchor):
      return anchor
    }
  }
}

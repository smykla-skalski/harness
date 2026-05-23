import AppIntents
import Foundation
import HarnessMonitorKit

public enum MergeMethodEnum: String, AppEnum, Sendable {
  case squash
  case merge
  case rebase

  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Merge Method")
  }

  public static var caseDisplayRepresentations: [MergeMethodEnum: DisplayRepresentation] {
    [
      .squash: DisplayRepresentation(title: "Squash and merge"),
      .merge: DisplayRepresentation(title: "Create a merge commit"),
      .rebase: DisplayRepresentation(title: "Rebase and merge")
    ]
  }

  public var daemonValue: TaskBoardGitHubMergeMethod {
    switch self {
    case .squash: .squash
    case .merge: .merge
    case .rebase: .rebase
    }
  }
}

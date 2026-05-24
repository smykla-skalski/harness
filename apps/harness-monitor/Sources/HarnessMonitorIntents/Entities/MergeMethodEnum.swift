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

  public static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
    [
      .squash: DisplayRepresentation(title: "Squash and merge"),
      .merge: DisplayRepresentation(title: "Create a merge commit"),
      .rebase: DisplayRepresentation(title: "Rebase and merge"),
    ]
  }

  public var daemonValue: TaskBoardGitHubMergeMethod {
    switch self {
    case .squash: .squash
    case .merge: .merge
    case .rebase: .rebase
    }
  }

  /// Phrase used in the confirmation prompt. Reads naturally as
  /// "Squash and merge PR title?" - much clearer than the daemon
  /// raw value which produces awkward forms like "Merge PR using merge?"
  public var confirmationVerbPhrase: String {
    switch self {
    case .squash: "Squash and merge"
    case .merge: "Merge"
    case .rebase: "Rebase and merge"
    }
  }

  /// Phrase used in the success dialog after a merge completes. Reads
  /// as "Merged PR title via Squash and merge" - groups the past-tense
  /// outcome with the chosen strategy without forcing the user to
  /// parse parenthetical raw enum values
  public var pastDescriptor: String {
    switch self {
    case .squash: "Squash and merge"
    case .merge: "Merge commit"
    case .rebase: "Rebase and merge"
    }
  }
}

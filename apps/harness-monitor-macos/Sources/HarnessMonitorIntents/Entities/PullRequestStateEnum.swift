import AppIntents
import Foundation
import HarnessMonitorKit

public enum PullRequestStateEnum: String, AppEnum, Sendable {
  case open
  case draft
  case closed
  case merged

  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Pull Request State")
  }

  public static var caseDisplayRepresentations: [PullRequestStateEnum: DisplayRepresentation] {
    [
      .open: DisplayRepresentation(title: "Open"),
      .draft: DisplayRepresentation(title: "Draft"),
      .closed: DisplayRepresentation(title: "Closed"),
      .merged: DisplayRepresentation(title: "Merged")
    ]
  }

  public init(reviewState: ReviewPullRequestState, isDraft: Bool) {
    if isDraft {
      self = .draft
      return
    }
    switch reviewState {
    case .open:
      self = .open
    case .closed:
      self = .closed
    case .merged:
      self = .merged
    case .unknown:
      self = .closed
    }
  }
}

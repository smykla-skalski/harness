import AppIntents
import Foundation

/// Enum surface for the parametric `PerformReviewActionIntent`. Shortcuts
/// users pick a verb (Approve / Merge / Rerun Checks / Add Label) at
/// shortcut-build time without committing to a specific Intent class.
/// Specific intents (`ApprovePullRequestIntent` etc.) stay for callers
/// that already know the verb and want to avoid the extra parameter
public enum ReviewActionEnum: String, AppEnum, Sendable {
  case approve
  case merge
  case rerunChecks
  case addLabel

  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Review Action")
  }

  public static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
    [
      .approve: DisplayRepresentation(title: "Approve"),
      .merge: DisplayRepresentation(title: "Merge"),
      .rerunChecks: DisplayRepresentation(title: "Rerun checks"),
      .addLabel: DisplayRepresentation(title: "Add label")
    ]
  }
}

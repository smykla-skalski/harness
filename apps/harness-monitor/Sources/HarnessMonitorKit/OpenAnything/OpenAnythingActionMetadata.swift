import SwiftUI

/// Action metadata helpers for the Open Anything corpus.
///
/// Each per-action lookup delegates to ``OpenAnythingAction`` so the compiler
/// enforces exhaustiveness when a new action is added. Free-standing data that
/// is not per-action - currently the ``suggestedActions`` set - continues to
/// live here.
extension OpenAnythingCorpusBuilder {
  static func actionTitle(_ action: OpenAnythingAction) -> String {
    action.title
  }

  static func actionTitleKey(_ action: OpenAnythingAction) -> LocalizedStringKey {
    action.titleKey
  }

  static func actionSubtitle(_ action: OpenAnythingAction) -> String {
    action.subtitle
  }

  static func actionSubtitleKey(_ action: OpenAnythingAction) -> LocalizedStringKey {
    action.subtitleKey
  }

  static func actionSystemImage(_ action: OpenAnythingAction) -> String {
    action.systemImage
  }

  static func actionSearchAliases(_ action: OpenAnythingAction) -> String {
    action.searchAliases
  }

  /// Actions surfaced in the empty palette as suggested commands. Defined here
  /// rather than on ``OpenAnythingAction`` because suggestion membership is a
  /// product decision, not an intrinsic property of the action.
  static let suggestedActions: Set<OpenAnythingAction> = [
    .newSession,
    .openTaskBoard,
    .openReviews,
    .openDiagnostics,
    .refresh,
  ]
}

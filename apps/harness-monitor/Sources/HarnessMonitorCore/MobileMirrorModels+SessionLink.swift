import Foundation

extension MobileAttentionItem {
  /// Session id to open when this attention item relates to a mirrored session that
  /// is still present in the list; nil otherwise. Covers blocked-agent and ACP
  /// decision items whose target names a session (other kinds, a missing target, or
  /// a session that is no longer mirrored all yield nil).
  public func navigableSessionID(in sessions: [MobileSessionSummary]) -> String? {
    guard kind == .blockedAgent || kind == .acpDecision,
      let sessionID = target?.sessionID,
      sessions.contains(where: { $0.id == sessionID })
    else {
      return nil
    }
    return sessionID
  }
}

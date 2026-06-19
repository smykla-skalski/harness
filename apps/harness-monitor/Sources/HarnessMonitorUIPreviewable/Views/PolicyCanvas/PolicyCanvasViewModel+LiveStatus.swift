import HarnessMonitorKit

/// Persistent LIVE/DRAFT anchor for the policy canvas. Derived from the daemon
/// audit (the active enforced revision + mode) versus the draft the user is
/// editing. Replaces the old three-mode Promotion lens with one honest "what is
/// governing real work right now" signal.
enum PolicyCanvasLiveState: Equatable {
  /// No daemon-backed policy yet (fresh canvas, lab, or pre-first-load).
  case noPolicy
  /// The draft equals the active enforced revision with no local edits.
  case live(revision: UInt64)
  /// Local edits, or a revision that has not been made live. `liveRevision` is
  /// the currently enforced revision when one exists, else nil.
  case draft(liveRevision: UInt64?)

  var isLive: Bool {
    if case .live = self {
      return true
    }
    return false
  }
}

extension PolicyCanvasViewModel {
  /// Store the daemon audit so the live anchor can compare the active enforced
  /// revision against the draft. Mirrors the `latestSimulation` preserve rule:
  /// a nil audit (e.g. a document-only push) never blanks the anchor.
  func captureLiveAudit(_ audit: TaskBoardPolicyPipelineAuditSummary?) {
    if let audit {
      latestAudit = audit
    }
  }

  /// The persistent LIVE/DRAFT anchor shown in the top bar. LIVE means the draft
  /// equals the active revision, that revision is enforced, and there are no
  /// unsaved edits; everything else is DRAFT.
  var liveStatus: PolicyCanvasLiveState {
    guard let audit = latestAudit, let draftRevision = backingDocument?.revision else {
      return backingDocument == nil ? .noPolicy : .draft(liveRevision: nil)
    }
    let enforcedRevision = audit.mode == .enforced ? audit.activeRevision : nil
    if documentDirty || draftRevision != audit.activeRevision || audit.mode != .enforced {
      return .draft(liveRevision: enforcedRevision)
    }
    return .live(revision: audit.activeRevision)
  }
}

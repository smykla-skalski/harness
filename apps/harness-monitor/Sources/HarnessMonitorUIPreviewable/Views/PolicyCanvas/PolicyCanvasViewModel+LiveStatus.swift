import Foundation
import HarnessMonitorKit

/// Persistent LIVE/DRAFT anchor for the policy canvas. Derived from the daemon
/// audit (the active enforced revision + mode) versus the draft the user is
/// editing. Replaces the old three-mode Promotion lens with one honest "what is
/// governing real work right now" signal.
enum PolicyCanvasLiveState: Equatable {
  /// No daemon-backed policy yet (fresh canvas, lab, or pre-first-load).
  case noPolicy
  /// The draft equals the active enforced revision with no local edits.
  case live(revision: UInt64, publishedAt: Date?)
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
  func captureLiveAudit(_ audit: PolicyPipelineAuditSummary?) {
    if let audit {
      latestAudit = audit
      globalPolicyEnforcementEnabled = audit.globalPolicyEnforcementEnabled
    }
  }

  func captureLiveWorkspace(_ workspace: PolicyCanvasWorkspace?, activeCanvasId: String?) {
    guard let workspace else {
      livePublishedAt = nil
      return
    }
    globalPolicyEnforcementEnabled = workspace.globalPolicyEnforcementEnabled
    let resolvedCanvasId = activeCanvasId ?? workspace.activeCanvasId
    livePublishedAt = workspace.canvases.first { canvas in
      canvas.canvasId == resolvedCanvasId
    }.flatMap { canvas in
      PolicyCanvasLiveStatusDateFormatting.date(from: canvas.liveUpdatedAt ?? canvas.updatedAt)
    }
  }

  /// The persistent LIVE/DRAFT anchor shown in the top bar. LIVE means the draft
  /// equals the active revision, that revision is enforced, global enforcement is
  /// enabled, and there are no unsaved edits; everything else is DRAFT.
  var liveStatus: PolicyCanvasLiveState {
    guard let audit = latestAudit, let draftRevision = backingDocument?.revision else {
      return backingDocument == nil ? .noPolicy : .draft(liveRevision: nil)
    }
    let enforcedRevision =
      globalPolicyEnforcementEnabled && audit.mode == .enforced ? audit.activeRevision : nil
    if documentDirty || draftRevision != audit.activeRevision || enforcedRevision == nil {
      return .draft(liveRevision: enforcedRevision)
    }
    return .live(revision: audit.activeRevision, publishedAt: livePublishedAt)
  }

  /// Whether the draft can be made the live, enforced policy right now.
  var canMakeLive: Bool {
    makeLiveDisabledReason == nil
  }

  /// First reason make-live is blocked, or nil when it is allowed. Make-live no
  /// longer carries the old promote bookkeeping (saved-matching-simulation /
  /// run-simulation-for-revision): the daemon re-simulates inside
  /// `apply_make_live`, so the real gates are a validation error, a
  /// not-yet-saved canvas, an in-flight save, and local edits that have not
  /// reached the saved backing document yet. The chrome surfaces this string as
  /// the disabled button's help text.
  var makeLiveDisabledReason: String? {
    let errors = validationErrorCount
    if errors > 0 {
      return errors == 1 ? "Fix 1 validation error first" : "Fix \(errors) validation errors first"
    }
    guard backingDocument != nil else {
      return "Save a draft before making it live"
    }
    if isSavingDraft {
      return "Finish saving before making live"
    }
    if documentDirty {
      return "Save pending changes before making live"
    }
    return nil
  }
}

@MainActor
enum PolicyCanvasLiveStatusDateFormatting {
  private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  static func date(from value: String) -> Date? {
    iso8601WithFractionalSeconds.date(from: value) ?? iso8601.date(from: value)
  }
}

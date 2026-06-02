import CoreGraphics
import Foundation

public struct PolicyCanvasPortEndpoint: Hashable, Sendable {
  public let nodeID: String
  public let portID: String
  public let kind: PolicyCanvasPortKind
  public var side: PolicyCanvasPortSide?

  public init(
    nodeID: String,
    portID: String,
    kind: PolicyCanvasPortKind,
    side: PolicyCanvasPortSide? = nil
  ) {
    self.nodeID = nodeID
    self.portID = portID
    self.kind = kind
    self.side = side
  }
}

/// Semantic kind of a `PolicyCanvasEdge`. Drives stroke color so the canvas
/// reader can distinguish unconditional flow, conditional control branches,
/// and error/deny paths at a glance. Mapped from the daemon `condition`
/// string in `policyCanvasEdge(_:)`; defaults to `.flow` for `"always"` so
/// untyped historical edges keep the existing neutral hue.
public enum PolicyCanvasEdgeKind: String, Hashable, CaseIterable, Sendable {
  case flow
  case control
  case error

  /// Dash pattern paired with `accentColor` so the kind distinction is
  /// readable for users who cannot perceive the color encoding (deuteranopia,
  /// protanopia, tritanopia, monochromacy, inverted modes). Solid for the
  /// unconditional `.flow` case; widely-spaced dashes for `.control`
  /// (conditional branches read as "occasional"); tight dashes for `.error`
  /// (reads as "urgent"). Composes with the animated dash overlay: when an
  /// edge is animated, the animation layer's pattern wins; this static
  /// pattern is the fallback for non-animated strokes only.
  public var strokeDashPattern: [CGFloat] {
    switch self {
    case .flow:
      []
    case .control:
      [6, 4]
    case .error:
      [4, 5]
    }
  }

  /// Lowercase word used by VoiceOver to name this kind. Matches the
  /// rawValue today (`flow` / `control` / `error`) but is split out so the
  /// accessible label is decoupled from the storage identifier - if a
  /// rawValue ever changes for serialization reasons, the spoken word
  /// stays stable.
  public var accessibilityWord: String {
    switch self {
    case .flow:
      "flow"
    case .control:
      "control"
    case .error:
      "error"
    }
  }

  /// Plain-English description of the stroke's dash pattern. Single
  /// source of truth for the three surfaces that describe the dash
  /// encoding to the user: the legend swatch label, the hover tooltip,
  /// and the VoiceOver accessibility value paired with each legend row.
  /// Keeping them unified avoids the Nielsen consistency violation
  /// where one surface said "dense" and another said "tightly dashed"
  /// for the same stroke. The name is "description" rather than "key"
  /// because the value is user-facing prose, not a stable identifier.
  /// The strings are English-only today (matching the rest of this
  /// surface's copy); add localization when the rest of the app
  /// gains a localization story.
  public var dashDescription: String {
    switch self {
    case .flow:
      "solid"
    case .control:
      "widely dashed"
    case .error:
      "tightly dashed"
    }
  }
}

/// One underlying daemon edge inside a (possibly merged) `PolicyCanvasEdge`.
///
/// Convergent edges that share both endpoints are one logical transition the
/// daemon splits into several `reason_code` branches (the default policy's four
/// `evidence:merge:fail -> supervisor:merge-deny` edges are exactly this). Per
/// algorithm-diagram convention a multigraph collapses to a single drawn edge,
/// so the canvas folds such a family into one merged wire and keeps the
/// per-edge distinctions here as metadata. A non-merged edge holds exactly one
/// branch mirroring the edge; a merged edge holds the parallel daemon edges.
///
/// Each branch keeps its own `daemonEdgeID` so export re-emits stable ids and a
/// later split restores the exact prior id. `target` is per-branch so a future
/// re-target can split one branch out of the merge without disturbing the rest;
/// today every branch of a merged edge shares the edge's target.
public struct PolicyCanvasEdgeBranch: Identifiable, Hashable, Sendable {
  public var daemonEdgeID: String
  /// The daemon `reason_code` this branch routes on (`nil` for unconditional or
  /// reason-less edges). Read from `condition.reasonCode` on load and written
  /// back on export, so failure types can branch to different targets.
  public var reasonCode: String?
  public var condition: String
  public var label: String
  public var target: PolicyCanvasPortEndpoint

  public var id: String { daemonEdgeID }

  public init(
    daemonEdgeID: String,
    reasonCode: String?,
    condition: String,
    label: String,
    target: PolicyCanvasPortEndpoint
  ) {
    self.daemonEdgeID = daemonEdgeID
    self.reasonCode = reasonCode
    self.condition = condition
    self.label = label
    self.target = target
  }
}

public struct PolicyCanvasEdge: Identifiable, Hashable, Sendable {
  public let id: String
  public var source: PolicyCanvasPortEndpoint
  public var target: PolicyCanvasPortEndpoint
  public var label: String
  /// Free-form condition string surfaced by the inspector for user editing.
  /// Defaults to `"always"` to match the daemon's wire shape; the document
  /// round-trip preserves any other `TaskBoardPolicyPipelineEdgeCondition`
  /// fields (actions, reasonCode) through the `originalEdgeConditions` cache
  /// on `exportDocument()`, overriding only the `condition` string the user
  /// edited here.
  public var condition: String
  /// When `false`, the visibility router is allowed to pick any of the four
  /// node sides for source and target anchors, choosing the combination that
  /// yields the fewest bends. Defaults to `true` so existing documents keep
  /// their stable port positions; flips off only when the user opts in via
  /// the inspector toggle (deferred UI surface, T2.2 follow-up).
  ///
  /// Default-true rationale: an author who positioned a port on the trailing
  /// side did so deliberately, and silently relocating that port when a new
  /// node enters the cheapest-bend combination would break their spatial
  /// memory. Flex is an explicit opt-in, not a default. **Delete-by**: if
  /// the inspector toggle has not shipped by the time the next router
  /// iteration lands (or the hand-coded router is removed), delete this
  /// field and the flex-anchor codepath on `PolicyCanvasVisibilityRouter`
  /// rather than carrying dormant code indefinitely.
  public var pinnedPortSide: Bool
  /// Semantic kind used to pick the stroke color. Derived from `condition`
  /// at construction by `PolicyCanvasEdgeKind.derive(from:)`; can be
  /// overridden at the model boundary if the daemon ever surfaces an
  /// explicit kind field.
  public var kind: PolicyCanvasEdgeKind
  /// When `true`, the stroke renders an animated dashed phase to suggest
  /// flow direction. Gated on reduce-motion at the render layer so the
  /// animation collapses to a static dashed stroke when the user has
  /// reduce-motion enabled. Defaults to `false`; the live runtime
  /// visualization layer wires this on per its own signal (deferred -
  /// daemon does not emit a "live edge" event today).
  ///
  /// **Delete-by**: if the daemon's live-edge event has not landed by the
  /// time the next tier of canvas work ships, delete this field and the
  /// `TimelineView`-wrapped animation path in `PolicyCanvasInteractiveEdge`
  /// rather than carrying dormant storage indefinitely. The animation
  /// surface is meaningless without a real producer wiring it on, and
  /// keeping the field as `Bool = false` everywhere is the storage-side
  /// version of the dead-code smell the `pinnedPortSide` doc above
  /// documents.
  public var isAnimated: Bool
  /// The underlying daemon edges this wire stands for. A non-merged edge has
  /// exactly one branch mirroring it; a merged edge has more than one, sharing
  /// `source`/`target`. Routing, markers, selection, and export all treat the
  /// merged edge as the single unit, so a convergent fan-in draws as one clean
  /// wire while still round-tripping to its N daemon edges.
  public var branches: [PolicyCanvasEdgeBranch]

  /// True when this wire stands for more than one daemon edge (a folded
  /// convergent family). Drives the inspector's per-branch editing surface and
  /// the merged accessibility description.
  public var isMerged: Bool { branches.count > 1 }

  /// Whether the router treats this edge's source/target ports as pinned
  /// for routing. `.error` edges are always pinned regardless of
  /// `pinnedPortSide`: an author who placed a deny-branch port on a
  /// specific side did so deliberately, and the flex pass silently
  /// relocating it would turn a slip in the routing layer into a
  /// safety-critical visual confusion. Norman R2 sev1 forcing function:
  /// pin error edges as a hard constraint rather than a default the
  /// user has to remember to re-set.
  public var effectivePinnedPortSide: Bool {
    kind == .error || pinnedPortSide
  }

  public init(
    id: String,
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint,
    label: String,
    condition: String = "always",
    pinnedPortSide: Bool = true,
    kind: PolicyCanvasEdgeKind? = nil,
    isAnimated: Bool = false,
    reasonCode: String? = nil,
    branches: [PolicyCanvasEdgeBranch]? = nil
  ) {
    self.id = id
    self.source = source
    self.target = target
    self.label = label
    self.condition = condition
    self.pinnedPortSide = pinnedPortSide
    self.kind = kind ?? PolicyCanvasEdgeKind.derive(from: condition)
    self.isAnimated = isAnimated
    // A non-merged edge synthesizes one branch mirroring itself, keyed by the
    // edge's own daemon id so existing edges and their selection ids stay
    // byte-identical. Callers that fold a family pass the branch list explicitly.
    self.branches =
      branches
      ?? [
        PolicyCanvasEdgeBranch(
          daemonEdgeID: id,
          reasonCode: reasonCode,
          condition: condition,
          label: label,
          target: target
        )
      ]
  }
}

public extension PolicyCanvasEdgeKind {
  /// Map a daemon condition string to a semantic kind. The mapping is a
  /// heuristic until the daemon ships an explicit `kind` field; until then,
  /// callers can override via the `kind:` parameter on `PolicyCanvasEdge.init`.
  ///
  /// Rules (in order):
  /// 1. Empty / `"always"` -> `.flow` (unconditional).
  /// 2. Token-level match against a human-workflow prefix set
  ///    (`review`, `manual`, `approv`, `audit`) -> `.control`. This prevents
  ///    false positives like `human_review_denied` or `manual_approval`
  ///    landing in `.error` purely because the condition text mentions a
  ///    denial outcome from a human gate. The match is word-boundary
  ///    (tokens split on non-alphanumeric characters), not substring, so
  ///    `predeny` does not match `deny`.
  /// 3. Token-level match against an error-marker set (`denied`, `deny`,
  ///    `error`, `errors`, `reject`, `rejected`, `failed`, `fail`,
  ///    `failure`) -> `.error`.
  /// 4. Otherwise -> `.flow`. The policy-flow domain is mostly flow:
  ///    conditions like `"normalize"`, `"low risk"`, `"allow"` describe
  ///    data moving through a step, not a decision gate. Generic
  ///    expressions like `"if x > 5"` also default to flow because a
  ///    bare predicate without human-workflow or error markers is more
  ///    likely a forwarding rule than a control branch.
  ///
  /// The token-boundary discipline plus the human-workflow short-circuit
  /// are the two changes that turn the prior substring heuristic into
  /// something safe enough to ship without a daemon-side kind field. The
  /// underlying ambiguity (`deny_list_member` could be a control branch or
  /// an error path depending on the document author's intent) is resolved
  /// by the explicit `kind:` override on `PolicyCanvasEdge.init`.
  static func derive(from condition: String) -> PolicyCanvasEdgeKind {
    let lowered = condition.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if lowered.isEmpty || lowered == "always" {
      return .flow
    }
    if lowered == "condition_true" || lowered == "condition_false" {
      return .control
    }
    let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
    let humanPrefixes = ["review", "manual", "approv", "audit"]
    if tokens.contains(where: { token in
      humanPrefixes.contains(where: { token.hasPrefix($0) })
    }) {
      return .control
    }
    let errorMarkers: Set<String> = [
      "denied", "deny", "error", "errors",
      "reject", "rejected", "failed", "fail", "failure",
    ]
    if tokens.contains(where: { errorMarkers.contains($0) }) {
      return .error
    }
    return .flow
  }
}

import HarnessMonitorKit
import SwiftUI

enum PolicyCanvasTab: String, CaseIterable, Identifiable {
  case draft
  case simulation
  case promotion

  var id: String { rawValue }

  var title: String {
    switch self {
    case .draft:
      "Draft"
    case .simulation:
      "Simulation"
    case .promotion:
      "Promotion"
    }
  }
}

enum PolicyCanvasNodeKind: String, CaseIterable, Identifiable {
  case source
  case condition
  case review
  case transform
  case decision

  var id: String { rawValue }

  var title: String {
    switch self {
    case .source:
      "Source"
    case .condition:
      "Condition"
    case .review:
      "Review"
    case .transform:
      "Transform"
    case .decision:
      "Decision"
    }
  }

  var subtitle: String {
    switch self {
    case .source:
      "Event intake"
    case .condition:
      "Policy rule"
    case .review:
      "Human gate"
    case .transform:
      "Context map"
    case .decision:
      "Outcome"
    }
  }

  var symbolName: String {
    switch self {
    case .source:
      "tray.and.arrow.down"
    case .condition:
      "line.3.horizontal.decrease.circle"
    case .review:
      "person.badge.shield.checkmark"
    case .transform:
      "arrow.triangle.branch"
    case .decision:
      "checkmark.seal"
    }
  }

  var accentColor: Color {
    switch self {
    case .source:
      Color.cyan
    case .condition:
      Color.indigo
    case .review:
      Color.orange
    case .transform:
      Color.mint
    case .decision:
      Color.green
    }
  }

  var inputPortTitles: [String] {
    switch self {
    case .source:
      []
    case .condition:
      ["event"]
    case .review:
      ["policy"]
    case .transform:
      ["context"]
    case .decision:
      ["result"]
    }
  }

  var outputPortTitles: [String] {
    switch self {
    case .source:
      ["event"]
    case .condition:
      ["pass", "fail"]
    case .review:
      ["approved", "denied"]
    case .transform:
      ["mapped"]
    case .decision:
      ["promote"]
    }
  }
}

enum PolicyCanvasPortKind: String {
  case input
  case output
}

enum PolicyCanvasPortSide: String, Hashable {
  case leading
  case trailing
  case top
  case bottom
}

struct PolicyCanvasPort: Identifiable, Hashable {
  let id: String
  let title: String
  let kind: PolicyCanvasPortKind
}

struct PolicyCanvasNode: Identifiable {
  let id: String
  var title: String
  var subtitle: String
  var kind: PolicyCanvasNodeKind
  var position: CGPoint
  var groupID: String?
  var policyKind: TaskBoardPolicyPipelineNodeKind?
  var inputPorts: [PolicyCanvasPort]
  var outputPorts: [PolicyCanvasPort]

  init(id: String, title: String, kind: PolicyCanvasNodeKind, position: CGPoint) {
    self.id = id
    self.title = title
    self.subtitle = kind.subtitle
    self.kind = kind
    self.position = position
    self.groupID = nil
    self.policyKind = nil
    self.inputPorts = kind.inputPortTitles.map { title in
      PolicyCanvasPort(
        id: "\(PolicyCanvasPortKind.input.rawValue)-\(title)",
        title: title,
        kind: .input
      )
    }
    self.outputPorts = kind.outputPortTitles.map { title in
      PolicyCanvasPort(
        id: "\(PolicyCanvasPortKind.output.rawValue)-\(title)",
        title: title,
        kind: .output
      )
    }
  }
}

enum PolicyCanvasGroupTone: String, CaseIterable {
  case intake
  case evaluation
  case release

  var color: Color {
    switch self {
    case .intake:
      Color.cyan
    case .evaluation:
      Color.purple
    case .release:
      Color.green
    }
  }

  var hexColor: String {
    switch self {
    case .intake:
      "#58d7f2"
    case .evaluation:
      "#bb7bff"
    case .release:
      "#72d989"
    }
  }
}

struct PolicyCanvasGroup: Identifiable {
  let id: String
  var title: String
  var frame: CGRect
  var tone: PolicyCanvasGroupTone
}

struct PolicyCanvasPortEndpoint: Hashable {
  let nodeID: String
  let portID: String
  let kind: PolicyCanvasPortKind
  var side: PolicyCanvasPortSide? = nil
}

struct PolicyCanvasEdge: Identifiable, Hashable {
  let id: String
  var source: PolicyCanvasPortEndpoint
  var target: PolicyCanvasPortEndpoint
  var label: String
  /// Free-form condition string surfaced by the inspector for user editing.
  /// Defaults to `"always"` to match the daemon's wire shape; the document
  /// round-trip preserves any other `TaskBoardPolicyPipelineEdgeCondition`
  /// fields (actions, reasonCode) through the `originalEdgeConditions` cache
  /// on `exportDocument()`, overriding only the `condition` string the user
  /// edited here.
  var condition: String

  init(
    id: String,
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint,
    label: String,
    condition: String = "always"
  ) {
    self.id = id
    self.source = source
    self.target = target
    self.label = label
    self.condition = condition
  }
}

enum PolicyCanvasSelection: Hashable {
  case node(String)
  case group(String)
  case edge(String)
}

/// A single search hit produced by `PolicyCanvasViewModel.searchHits(query:)`.
/// Each variant carries the matched component's id, its rendered title (the
/// eye-readable original, not the diacritic-folded copy used for the match),
/// the matched range expressed in the folded title's indices plus a stable
/// score used for ranking.
///
/// The range is in the folded title's indices, not the original. The palette
/// renders the original title; the matched substring length is the same in the
/// folded copy because `folding(options: .diacriticInsensitive)` preserves
/// index alignment for the alphabetic characters this search targets. Edge
/// labels and group titles use the same convention. For titles whose length
/// changes under folding (rare in this app's policy domain), callers must skip
/// the highlight rather than risking an index mismatch.
enum PolicyCanvasSearchHit: Equatable {
  case node(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)
  case edge(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)
  case group(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)

  var sortScore: Int {
    switch self {
    case .node(_, _, _, let score),
      .edge(_, _, _, let score),
      .group(_, _, _, let score):
      return score
    }
  }

  var sortKey: String {
    switch self {
    case .node(let id, _, _, _),
      .edge(let id, _, _, _),
      .group(let id, _, _, _):
      return id
    }
  }

  var displayTitle: String {
    switch self {
    case .node(_, let title, _, _),
      .edge(_, let title, _, _),
      .group(_, let title, _, _):
      return title
    }
  }

  /// Convert the hit into a `PolicyCanvasSelection` payload for the view model.
  /// Single source of truth so the palette and any future call site (peer
  /// "jump to" surfaces, validation drilldowns) cannot drift on how a hit
  /// maps onto a selection.
  var selection: PolicyCanvasSelection {
    switch self {
    case .node(let id, _, _, _):
      return .node(id)
    case .edge(let id, _, _, _):
      return .edge(id)
    case .group(let id, _, _, _):
      return .group(id)
    }
  }
}

/// Identifier for the inspector text field that currently owns keyboard focus.
/// `PolicyCanvasView` holds a `@FocusState<PolicyCanvasFocusedField?>` and
/// gates the canvas-wide Delete/Backspace/Escape shortcut buttons on
/// `focusedField == nil` — without that gate the shortcut buttons fire while
/// the user is still typing in a TextField (e.g. Escape clears selection
/// mid-rename, Delete deletes the selected node from the canvas instead of
/// the character in the field).
enum PolicyCanvasFocusedField: Hashable {
  case nodeTitle
  case nodeSubtitle
  case groupTitle
  case edgeLabel
  case edgeCondition
  case reasonCode
  case ruleID
}

struct PolicyCanvasDeletionRequest: Identifiable, Equatable {
  let selection: PolicyCanvasSelection
  let title: String
  let message: String
  let confirmationTitle: String

  var id: PolicyCanvasSelection { selection }
}

/// Value-typed snapshot of the editable canvas graph (nodes, groups, edges,
/// selection, latest simulation). Captured by
/// `PolicyCanvasViewModel.snapshotState()` before any daemon round-trip that
/// might reject the export, and re-applied via `restoreState(_:)` on rejection
/// so local state never silently diverges from `backingDocument`.
///
/// Snapshot membership is intentionally narrow: zoom and viewport-dirty state
/// belong to `viewportDirty` (window-scoped) and stay outside this struct so
/// rollback never resets the user's pan or zoom. `documentDirty` is also
/// excluded — `restoreState(_:markDirty:reason:)` lets the caller decide
/// whether the restored state should be dirty (default `true` for retry flows,
/// `false` for "discard local edits" flows).
///
/// `latestSimulation` is captured so a save-reject + rollback restores the
/// validation panel to the pre-attempt simulation; without it, the daemon's
/// failed-simulation issues stay attached to a graph shape that no longer
/// matches them (e.g. an issue references an edge id that has been rolled
/// back out of `edges`).
struct PolicyCanvasSnapshot {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let selection: PolicyCanvasSelection?
  let latestSimulation: TaskBoardPolicyPipelineSimulationResult?
}

/// In-flight rubber-band edge preview while the user drags from an output
/// port. Holds the source endpoint plus its anchor point so callers can render
/// a Bézier curve from the port to the live cursor location. The cursor is
/// updated in canvas coordinates (`viewModel.canvasPoint(for:)`); the source
/// anchor stays fixed for the duration of the drag. Cleared on drop or cancel.
struct PolicyCanvasPendingEdgePreview: Equatable {
  let source: PolicyCanvasPortEndpoint
  let sourceAnchor: CGPoint
  var cursor: CGPoint
}

/// Named coordinate spaces used by gesture-coordinate translations within the
/// policy canvas. The workspace declares each space on the appropriate view
/// so DragGesture(coordinateSpace:) reads positions relative to the right
/// container regardless of the surrounding chrome layout.
enum PolicyCanvasCoordinateSpaces {
  /// Pre-scaling canvas content stack. Position values are in canvas units
  /// (before the workspace `scaleEffect`). Use `viewModel.canvasPoint(for:)`
  /// when the value is captured in scaled coordinates.
  static let canvas = "policy-canvas.workspace"
}

/// Outcome of the most recent autosave round-trip. Surfaced to the chrome so
/// the user knows the autosave subsystem is alive (`succeeded`), still
/// flushing (`pending`), or has hit a reject the manual Save button must
/// resolve (`failed`). `idle` is the cold-start state before any autosave
/// has fired, and stays in place after a manual save reload (autosave isn't
/// the most recent attempt anymore).
///
/// `.disabled(reason:)` is the decompensation state: after the consecutive
/// failure ceiling fires (see `PolicyCanvasViewModel.autosaveFailureCeiling`),
/// the autosave scheduler refuses to fire and the chrome shows a sticky
/// affordance telling the user to save manually. A successful manual save
/// clears the failure counter and flips back to `succeeded(at:)`.
enum PolicyCanvasAutosaveOutcome: Equatable {
  case idle
  case pending
  case succeeded(at: Date)
  case failed(at: Date)
  case disabled(reason: String)
}


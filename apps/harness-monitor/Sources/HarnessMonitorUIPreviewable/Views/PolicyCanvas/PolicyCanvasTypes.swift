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

enum PolicyCanvasNodeCategory: String, CaseIterable, Identifiable, Sendable {
  case source
  case condition
  case review
  case transform
  case decision

  var id: String { rawValue }
}

enum PolicyCanvasNodeLibrarySection: String, CaseIterable, Identifiable, Sendable {
  case sources
  case conditions
  case reviewGates = "review_gates"
  case orchestration
  case outcomes

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sources:
      "Sources"
    case .conditions:
      "Conditions"
    case .reviewGates:
      "Review gates"
    case .orchestration:
      "Orchestration"
    case .outcomes:
      "Outcomes"
    }
  }
}

enum PolicyCanvasNodeAccentStyle: Equatable, Sendable {
  case category
  case activeTint
  case branchingTint
}

struct PolicyCanvasNodeKind: RawRepresentable, Identifiable, Hashable, Sendable {
  let rawValue: String
  let title: String
  let subtitle: String
  let symbolName: String
  let category: PolicyCanvasNodeCategory
  let accentStyle: PolicyCanvasNodeAccentStyle
  let librarySection: PolicyCanvasNodeLibrarySection
  let inputPortTitles: [String]
  let outputPortTitles: [String]
  let libraryTitle: String
  let librarySubtitle: String
  let defaultPolicyKind: TaskBoardPolicyPipelineNodeKind

  var id: String { rawValue }

  var accentColor: Color {
    PolicyCanvasVisualStyle.nodeTint(for: self)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue == rhs.rawValue
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(rawValue)
  }

  init?(rawValue: String) {
    guard let kind = Self.lookup[rawValue] else {
      return nil
    }
    self = kind
  }

  init(
    rawValue: String,
    title: String,
    subtitle: String,
    symbolName: String,
    category: PolicyCanvasNodeCategory,
    accentStyle: PolicyCanvasNodeAccentStyle = .category,
    librarySection: PolicyCanvasNodeLibrarySection,
    inputPortTitles: [String],
    outputPortTitles: [String],
    libraryTitle: String,
    librarySubtitle: String,
    defaultPolicyKind: TaskBoardPolicyPipelineNodeKind
  ) {
    self.rawValue = rawValue
    self.title = title
    self.subtitle = subtitle
    self.symbolName = symbolName
    self.category = category
    self.accentStyle = accentStyle
    self.librarySection = librarySection
    self.inputPortTitles = inputPortTitles
    self.outputPortTitles = outputPortTitles
    self.libraryTitle = libraryTitle
    self.librarySubtitle = librarySubtitle
    self.defaultPolicyKind = defaultPolicyKind
  }
}

enum PolicyCanvasPortKind: String, Sendable {
  case input
  case output
}

enum PolicyCanvasPortSide: String, Hashable, Sendable {
  case leading
  case trailing
  case top
  case bottom

  static let allSides: [Self] = [.leading, .trailing, .top, .bottom]
}

struct PolicyCanvasPort: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let kind: PolicyCanvasPortKind
}

struct PolicyCanvasNode: Equatable, Identifiable, Sendable {
  let id: String
  var title: String
  var subtitle: String
  var kind: PolicyCanvasNodeKind
  var position: CGPoint
  var layoutSource: TaskBoardPolicyPipelineNodeLayoutSource?
  var groupID: String?
  var policyKind: TaskBoardPolicyPipelineNodeKind?
  var automationBinding: TaskBoardPolicyPipelineAutomationBinding?
  var inputPorts: [PolicyCanvasPort]
  var outputPorts: [PolicyCanvasPort]

  init(id: String, title: String, kind: PolicyCanvasNodeKind, position: CGPoint) {
    self.id = id
    self.title = title
    self.subtitle = kind.subtitle
    self.kind = kind
    self.position = position
    self.layoutSource = .manual
    self.groupID = nil
    self.policyKind = nil
    self.automationBinding = nil
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

enum PolicyCanvasGroupTone: String, CaseIterable, Hashable, Sendable {
  case intake
  case evaluation
  case release

  var color: Color {
    PolicyCanvasVisualStyle.groupTint(for: self)
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

struct PolicyCanvasGroup: Identifiable, Hashable, Sendable {
  let id: String
  var title: String
  var frame: CGRect
  var tone: PolicyCanvasGroupTone
}

enum PolicyCanvasSelection: Hashable, Sendable {
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
  case workflow
  case workflowID
  case actionID
  case groupTitle
  case edgeLabel
  case edgeCondition
  case reasonCode
  case ruleID
  case waitDuration
  case waitEventKey
  case resumeKey
  case eventKey
  case handoffKey
  case automationAllowedApps
  case automationDeniedApps
  case automationReviewRepositories
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
struct PolicyCanvasSnapshot: Sendable {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let selection: PolicyCanvasSelection?
  let latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  let routingHints: PolicyCanvasLayoutRoutingHints?
}

/// In-flight rubber-band edge preview while the user drags from an output
/// port. Holds the source endpoint plus its anchor point so callers can render
/// a Bézier curve from the port to the live cursor location. The cursor is
/// updated in canvas coordinates; the source anchor stays fixed for the
/// duration of the drag. Cleared on drop or cancel.
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
  /// Canvas document space inside the native scroll host. Position values are
  /// already expressed in canvas units, even while AppKit magnification is
  /// active.
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

import CoreGraphics
import Foundation
import HarnessMonitorPolicyModels

public enum PolicyCanvasTab: String, CaseIterable, Identifiable {
  case draft
  case simulation
  case promotion

  public var id: String { rawValue }

  public var title: String {
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

public enum PolicyCanvasNodeCategory: String, CaseIterable, Identifiable, Sendable {
  case source
  case condition
  case review
  case transform
  case decision

  public var id: String { rawValue }
}

public enum PolicyCanvasNodeLibrarySection: String, CaseIterable, Identifiable, Sendable {
  case sources
  case conditions
  case reviewGates = "review_gates"
  case orchestration
  case outcomes

  public var id: String { rawValue }

  public var title: String {
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

public enum PolicyCanvasNodeAccentStyle: Equatable, Sendable {
  case category
  case activeTint
  case branchingTint
}

public struct PolicyCanvasNodeKind: RawRepresentable, Identifiable, Hashable, Sendable {
  public let rawValue: String
  public let title: String
  public let subtitle: String
  public let symbolName: String
  public let category: PolicyCanvasNodeCategory
  public let accentStyle: PolicyCanvasNodeAccentStyle
  public let librarySection: PolicyCanvasNodeLibrarySection
  public let inputPortTitles: [String]
  public let outputPortTitles: [String]
  public let libraryTitle: String
  public let librarySubtitle: String
  public let defaultPolicyKind: TaskBoardPolicyPipelineNodeKind

  public var id: String { rawValue }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue == rhs.rawValue
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(rawValue)
  }

  public init?(rawValue: String) {
    guard let kind = Self.lookup[rawValue] else {
      return nil
    }
    self = kind
  }

  public init(
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

public enum PolicyCanvasPortKind: String, Sendable {
  case input
  case output
}

public enum PolicyCanvasPortSide: String, Hashable, Sendable {
  case leading
  case trailing
  case top
  case bottom

  public static let allSides: [Self] = [.leading, .trailing, .top, .bottom]
}

public struct PolicyCanvasPort: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let kind: PolicyCanvasPortKind

  public init(id: String, title: String, kind: PolicyCanvasPortKind) {
    self.id = id
    self.title = title
    self.kind = kind
  }
}

public struct PolicyCanvasNode: Equatable, Identifiable, Sendable {
  public let id: String
  public var title: String
  public var subtitle: String
  public var kind: PolicyCanvasNodeKind
  public var position: CGPoint
  public var layoutSource: TaskBoardPolicyPipelineNodeLayoutSource?
  public var groupID: String?
  public var policyKind: TaskBoardPolicyPipelineNodeKind?
  public var automationBinding: TaskBoardPolicyPipelineAutomationBinding?
  public var inputPorts: [PolicyCanvasPort]
  public var outputPorts: [PolicyCanvasPort]

  public init(id: String, title: String, kind: PolicyCanvasNodeKind, position: CGPoint) {
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

public enum PolicyCanvasGroupTone: String, CaseIterable, Hashable, Sendable {
  case intake
  case evaluation
  case release

  public var hexColor: String {
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

public struct PolicyCanvasGroup: Identifiable, Hashable, Sendable {
  public let id: String
  public var title: String
  public var frame: CGRect
  public var tone: PolicyCanvasGroupTone

  public init(id: String, title: String, frame: CGRect, tone: PolicyCanvasGroupTone) {
    self.id = id
    self.title = title
    self.frame = frame
    self.tone = tone
  }
}

public enum PolicyCanvasSelection: Hashable, Sendable {
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
public enum PolicyCanvasSearchHit: Equatable {
  case node(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)
  case edge(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)
  case group(id: String, displayTitle: String, matchedRange: Range<String.Index>?, score: Int)

  public var sortScore: Int {
    switch self {
    case .node(_, _, _, let score),
      .edge(_, _, _, let score),
      .group(_, _, _, let score):
      return score
    }
  }

  public var sortKey: String {
    switch self {
    case .node(let id, _, _, _),
      .edge(let id, _, _, _),
      .group(let id, _, _, _):
      return id
    }
  }

  public var displayTitle: String {
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
  public var selection: PolicyCanvasSelection {
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
public enum PolicyCanvasFocusedField: Hashable {
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

public struct PolicyCanvasDeletionRequest: Identifiable, Equatable {
  public let selection: PolicyCanvasSelection
  public let title: String
  public let message: String
  public let confirmationTitle: String

  public var id: PolicyCanvasSelection { selection }

  public init(
    selection: PolicyCanvasSelection,
    title: String,
    message: String,
    confirmationTitle: String
  ) {
    self.selection = selection
    self.title = title
    self.message = message
    self.confirmationTitle = confirmationTitle
  }
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
public struct PolicyCanvasSnapshot: Sendable {
  public let nodes: [PolicyCanvasNode]
  public let groups: [PolicyCanvasGroup]
  public let edges: [PolicyCanvasEdge]
  public let selection: PolicyCanvasSelection?
  public let latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  public let routingHints: PolicyCanvasLayoutRoutingHints?

  public init(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    selection: PolicyCanvasSelection?,
    latestSimulation: TaskBoardPolicyPipelineSimulationResult?,
    routingHints: PolicyCanvasLayoutRoutingHints?
  ) {
    self.nodes = nodes
    self.groups = groups
    self.edges = edges
    self.selection = selection
    self.latestSimulation = latestSimulation
    self.routingHints = routingHints
  }
}

/// In-flight rubber-band edge preview while the user drags from an output
/// port. Holds the source endpoint plus its anchor point so callers can render
/// a Bézier curve from the port to the live cursor location. The cursor is
/// updated in canvas coordinates; the source anchor stays fixed for the
/// duration of the drag. Cleared on drop or cancel.
public struct PolicyCanvasPendingEdgePreview: Equatable {
  public let source: PolicyCanvasPortEndpoint
  public let sourceAnchor: CGPoint
  public var cursor: CGPoint

  public init(source: PolicyCanvasPortEndpoint, sourceAnchor: CGPoint, cursor: CGPoint) {
    self.source = source
    self.sourceAnchor = sourceAnchor
    self.cursor = cursor
  }
}

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
}

enum PolicyCanvasSelection: Hashable {
  case node(String)
  case group(String)
  case edge(String)
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
  case groupTitle
  case edgeLabel
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

enum PolicyCanvasLayout {
  static let gridSize: CGFloat = 20
  static let nodeSize = CGSize(width: 168, height: 96)
  static let portDiameter: CGFloat = 18
  static let portHitTestExtension: CGFloat = 8
  static let groupCornerRadius: CGFloat = 8
  static let edgeLabelHeight: CGFloat = 28
  static let edgeLabelMaxWidth: CGFloat = 220
  static let edgeLabelLaneSpacing: CGFloat = 46
  static let edgeBusLaneSpacing: CGFloat = 38
  static let edgeLabelNodeClearance: CGFloat = 24
  static let edgeLabelHorizontalMargin: CGFloat = 14
  static let initialContentOrigin = CGPoint(x: 520, y: 480)
  static let groupHorizontalPadding: CGFloat = 44
  static let groupVerticalPadding: CGFloat = 52
  static let minimumGroupSize = CGSize(width: 220, height: 180)
  static let minimumCanvasSize = CGSize(width: 3_800, height: 3_000)
  static let canvasTrailingPadding: CGFloat = 1_200
  static let canvasBottomPadding: CGFloat = 1_200
  static let initialViewportAnchorID = "policy-canvas-initial-viewport-anchor"
  /// First center used when the user clicks a palette button. Subsequent
  /// clicks step away from this anchor by `paletteDropStep` so identical
  /// clicks don't pile on top of each other.
  static let initialPaletteDropAnchor = CGPoint(x: 640, y: 620)
  /// Per-click advance offset for palette button drops. 40pt = 2x grid step
  /// so the next drop lands cleanly on the grid and stays clear of the prior
  /// node frame.
  static let paletteDropStep: CGFloat = 40

  static func portY(index: Int, count: Int) -> CGFloat {
    guard count > 1 else {
      return nodeSize.height / 2
    }
    let step = min(CGFloat(24), nodeSize.height / CGFloat(count + 1))
    let top = (nodeSize.height - (step * CGFloat(count - 1))) / 2
    return top + (CGFloat(index) * step)
  }

  static func portX(index: Int, count: Int) -> CGFloat {
    guard count > 1 else {
      return nodeSize.width / 2
    }
    let step = min(CGFloat(32), nodeSize.width / CGFloat(count + 1))
    let leading = (nodeSize.width - (step * CGFloat(count - 1))) / 2
    return leading + (CGFloat(index) * step)
  }
}

import HarnessMonitorKit
import SwiftUI

/// Value-typed description of a single persistable canvas mutation, plus
/// enough state to compute the inverse. Wave 3H routes every undoable site
/// through `PolicyCanvasViewModel.mutate(_:)` so undo/redo registration lives
/// in one place — the view model never registers undo on a raw field write.
///
/// **Scope.** Document state only. Viewport mutations (`setZoom`),
/// selection-only writes (`select`), and transient gesture state
/// (`highlightedGroupID`, `highlightedInput`, `pendingEdgePreview`) are NOT
/// funnelled — macOS users expect Cmd+Z to roll back document edits, not pan
/// or scroll position.
///
/// **Coalescing rule.** Drag-tick writes (`dragNode`, `dragGroup`) stay
/// direct — the funnel registers a single inverse on drag-end, with `from =
/// the origin captured at gesture start`. Registering per-tick would flood
/// the undo stack with one entry per frame.
///
/// **Inverse pairing.** Add and remove cases are not symmetric: removing a
/// node must capture the incident edges and group membership so the inverse
/// can fully reconstruct the cascade, whereas adding a node has nothing to
/// preserve. The enum therefore distinguishes the simple add/move shapes
/// from the heavier `restore*` shapes that carry the rebuild payload.
enum PolicyCanvasChange {
  /// Add a fresh node. Inverse is `removeNode(id:)` which gathers incident
  /// edges at the moment of removal.
  case addNode(PolicyCanvasNode, restoreSelection: PolicyCanvasSelection?)

  /// Remove a node by id, cascading every incident edge. The remove path
  /// computes its own inverse payload by inspecting graph state when the
  /// mutation lands, so the caller does not need to gather edges in advance.
  case removeNode(id: String, priorSelection: PolicyCanvasSelection?)

  /// Restore a previously-removed node along with its incident edges and
  /// clean-ephemeral bookkeeping. Used as the inverse of `removeNode`.
  case restoreNode(
    PolicyCanvasNode,
    incidentEdges: [PolicyCanvasEdge],
    cleanEphemeralNodeIncluded: Bool,
    cleanEphemeralEdgeIDs: Set<String>,
    restoreSelection: PolicyCanvasSelection?
  )

  /// Move a node's stored position. Registered on drag-end with `from = the
  /// position at gesture start`; inverse moves the node back.
  case moveNode(id: String, from: CGPoint, to: CGPoint)

  /// Add an edge created by the rubber-band gesture. Inverse drops the edge.
  case addEdge(PolicyCanvasEdge, restoreSelection: PolicyCanvasSelection?)

  /// Remove an edge by id. Inverse re-adds it with its `cleanEphemeral`
  /// bookkeeping intact.
  case removeEdge(id: String, priorSelection: PolicyCanvasSelection?)

  /// Restore a previously-removed edge along with its clean-ephemeral
  /// bookkeeping. Used as the inverse of `removeEdge`.
  case restoreEdge(
    PolicyCanvasEdge,
    cleanEphemeralEdgeIncluded: Bool,
    restoreSelection: PolicyCanvasSelection?
  )

  /// Move a group origin plus every member node by the same delta. Registered
  /// on group drag-end. Member positions are captured both pre and post so
  /// repeated undo/redo lands at the same spots regardless of intervening
  /// reconciles.
  case moveGroup(
    id: String,
    fromOrigin: CGPoint,
    toOrigin: CGPoint,
    memberOrigins: [String: CGPoint],
    memberDestinations: [String: CGPoint]
  )

  /// Remove a group container, leaving member nodes on the canvas with
  /// `groupID = nil`. The remove path computes its own inverse payload from
  /// graph state when it lands.
  case removeGroup(id: String, priorSelection: PolicyCanvasSelection?)

  /// Restore a previously-removed group AND re-attach each member node's
  /// `groupID`. Used as the inverse of `removeGroup`.
  case restoreGroup(
    PolicyCanvasGroup,
    memberIDs: [String],
    restoreSelection: PolicyCanvasSelection?
  )

  /// Human-readable label surfaced by the system menu's "Undo X" / "Redo X"
  /// affordance. Matches the casing of menu-bar action names on macOS.
  var actionName: String {
    switch self {
    case .addNode, .restoreNode:
      return "Add Node"
    case .removeNode:
      return "Delete Node"
    case .moveNode:
      return "Move Node"
    case .addEdge, .restoreEdge:
      return "Add Connection"
    case .removeEdge:
      return "Delete Connection"
    case .moveGroup:
      return "Move Group"
    case .removeGroup, .restoreGroup:
      return "Delete Group"
    }
  }
}

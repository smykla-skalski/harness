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
  /// position at gesture start`; inverse moves the node back. The `fromGroupID`
  /// / `toGroupID` payload carries the node's group membership across the
  /// move so the inverse restores the prior membership. Drag-end and
  /// arrow-nudge both can auto-attach a node into a group it crosses into,
  /// or detach when it leaves; replaying that side effect on undo keeps the
  /// node's `groupID` consistent with the visible position after every step.
  case moveNode(
    id: String,
    from: CGPoint,
    to: CGPoint,
    fromGroupID: String?,
    toGroupID: String?
  )

  /// Bulk move: coalesced position writes across many nodes and groups in
  /// one undo step. Registered by arrow-nudge so a 10-node selection with
  /// shift+arrow held landed as a single Cmd+Z reversal instead of ten.
  /// Each node/group entry carries its own from/to so the inverse can land
  /// the displaced set back at its original positions; group entries also
  /// carry their member offsets so member nodes ride the inverse correctly.
  case bulkMove(
    nodeMoves: [PolicyCanvasNodeMove],
    groupMoves: [PolicyCanvasGroupMove]
  )

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

  /// Rename a node by writing a new title. Captures the from-string so the
  /// inverse restores the original. The funnel is used (rather than direct
  /// field write) so a Cmd+Z after a commit-on-Enter reverts the inline
  /// rename. The TextField binds through a local @State buffer and only
  /// fires this change on commit; per-keystroke writes do not flood the
  /// undo stack.
  case renameNode(id: String, from: String, to: String)

  /// Detach a node from its group, leaving the node on the canvas with
  /// `groupID = nil`. Inverse re-attaches the prior `groupID` (which may
  /// itself be nil if the node was never grouped). Used by the "Remove from
  /// group" right-click action and by Cmd+drag-out-of-group flows.
  case removeNodeFromGroup(id: String, fromGroupID: String?, toGroupID: String?)

  /// Bulk add of a previously-captured set of nodes/edges/groups. Used by
  /// paste and duplicate. Inverse is `bulkRemove` which removes by id in
  /// reverse order; the inverse-of-the-inverse re-applies this payload so
  /// Cmd+Z then Cmd+Shift+Z restores the same paste/duplicate result.
  /// `restoreSecondaries` captures the secondary-selection set that was
  /// active when the bulk add ran, so undoing a multi-select paste lands
  /// the pre-paste multi-selection back instead of dropping to primary only.
  case bulkAdd(
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge],
    groups: [PolicyCanvasGroup],
    restoreSelection: PolicyCanvasSelection?,
    restoreSecondaries: Set<PolicyCanvasSelection>,
    primarySelection: PolicyCanvasSelection?
  )

  /// Inverse of `bulkAdd`. Removes nodes/edges/groups by id; the apply path
  /// captures the full payload before removal so the inverse can rehydrate
  /// the exact insertion. Inserts never cascade — bulk add only inserts
  /// fresh ids, so removing them never strands a foreign edge.
  /// `restoreSecondaries` mirrors `.bulkAdd` so a redo of bulkRemove
  /// preserves whatever multi-selection state the user expects on return.
  case bulkRemove(
    nodeIDs: [String],
    edgeIDs: [String],
    groupIDs: [String],
    restoreSelection: PolicyCanvasSelection?,
    restoreSecondaries: Set<PolicyCanvasSelection>
  )

  /// Commit a node's title edit via the inspector commit-on-Enter pathway.
  /// Coexists with `renameNode`: `renameNode` is fired by the inline
  /// PolicyCanvasInspectorRenameField (legacy 4J path), `setNodeTitle` by
  /// the unified PolicyCanvasInspectorCommitTextField wrapper.
  case setNodeTitle(id: String, from: String, to: String)

  /// Commit a node's `PolicyCanvasNodeKind` swap. Carries the edges that the
  /// kind change would prune (ports of a new kind do not match the old ports,
  /// so dangling edges must be removed) so the inverse can restore both the
  /// prior kind and every pruned edge in one undo step. Without this, a kind
  /// switch silently dropped every incident edge and Cmd-Z left the user with
  /// the old kind back but no connections.
  case setNodeKind(
    id: String,
    from: PolicyCanvasNodeKind,
    to: PolicyCanvasNodeKind,
    fromSubtitle: String,
    toSubtitle: String,
    fromPolicyKind: TaskBoardPolicyPipelineNodeKind?,
    toPolicyKind: TaskBoardPolicyPipelineNodeKind?,
    removedEdges: [PolicyCanvasEdge]
  )

  /// Commit a node's group-membership change. `nil` means "no group". Inverse
  /// swaps `from` and `to`. Picker writes route through this so the user can
  /// Cmd-Z a drop-into-group misclick without re-dragging the node.
  case setNodeGroup(id: String, from: String?, to: String?)

  /// Commit a node's subtitle edit. Registered on Enter/focus-loss from the
  /// inspector's subtitle field — per-keystroke writes stay local @State,
  /// only the commit lands here so the undo stack carries one entry per
  /// committed edit, not one per character.
  case setNodeSubtitle(id: String, from: String, to: String)

  /// Commit a node's `policyKind` (daemon-side `TaskBoardPolicyPipelineNodeKind`)
  /// replacement. Inverse swaps `from` and `to`. Inspector picker writes go
  /// through this so the user can Cmd-Z a kind switch without re-typing the
  /// surrounding policy fields.
  case setNodePolicyKind(
    id: String,
    from: TaskBoardPolicyPipelineNodeKind?,
    to: TaskBoardPolicyPipelineNodeKind?
  )

  /// Commit a node's automation binding. Source nodes use this payload to
  /// compile app automation policies such as clipboard OCR without relying
  /// on title/subtitle text heuristics. `nil` means the node does not
  /// participate in automation policy compilation.
  case setNodeAutomationBinding(
    id: String,
    from: TaskBoardPolicyPipelineAutomationBinding?,
    to: TaskBoardPolicyPipelineAutomationBinding?
  )

  /// Commit an edge's free-form condition string edit. Registered on
  /// Enter/focus-loss from the inspector's condition field.
  case setEdgeCondition(id: String, from: String, to: String)

  /// Commit an edge's label edit. Routes through the commit funnel so the
  /// inspector commit-on-Enter+blur produces one undo entry per committed
  /// label, not one per character.
  case setEdgeLabel(id: String, from: String, to: String)

  /// Commit an edge's semantic kind (flow / control / error). Lands on a
  /// single Cmd-Z entry per inspector picker pick. Defaults to the
  /// heuristic-derived kind when an edge is constructed; the inspector
  /// override surfaces this case so the user can correct a misclassified
  /// condition string.
  case setEdgeKind(id: String, from: PolicyCanvasEdgeKind, to: PolicyCanvasEdgeKind)

  /// Toggle an edge's `pinnedPortSide` flag. When false, the visibility
  /// router walks all 4-side anchor combinations and picks the lowest-cost
  /// route. Inspector toggle writes land here so flipping the pin produces
  /// one undo entry.
  case setEdgePinnedPortSide(id: String, from: Bool, to: Bool)

  /// Commit a group's title edit. Same per-commit funnel rule as
  /// `setEdgeLabel` — inspector text fields keep local @State for keystrokes
  /// and route to this case only on commit.
  case setGroupTitle(id: String, from: String, to: String)

  /// Commit a group's tone replacement (intake/evaluation/release). Inverse
  /// swaps `from` and `to`. Inspector picker writes land here so the user
  /// sees a single Cmd-Z entry per tone change.
  case setGroupTone(id: String, from: PolicyCanvasGroupTone, to: PolicyCanvasGroupTone)

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
    case .bulkMove:
      return "Move Selection"
    case .addEdge, .restoreEdge:
      return "Add Connection"
    case .removeEdge:
      return "Delete Connection"
    case .moveGroup:
      return "Move Group"
    case .removeGroup, .restoreGroup:
      return "Delete Group"
    case .renameNode:
      return "Rename Node"
    case .removeNodeFromGroup:
      return "Remove from Group"
    case .bulkAdd:
      return "Paste"
    case .bulkRemove:
      return "Remove Items"
    case .setNodeTitle:
      return "Rename Node"
    case .setNodeKind:
      return "Change Node Kind"
    case .setNodeGroup:
      return "Change Node Group"
    case .setNodeSubtitle:
      return "Edit Subtitle"
    case .setNodePolicyKind:
      return "Edit Node Binding"
    case .setNodeAutomationBinding:
      return "Edit Automation Policy"
    case .setEdgeCondition:
      return "Edit Condition"
    case .setEdgeLabel:
      return "Edit Label"
    case .setEdgeKind:
      return "Change Edge Kind"
    case .setEdgePinnedPortSide:
      return "Toggle Port Pin"
    case .setGroupTitle:
      return "Rename Group"
    case .setGroupTone:
      return "Edit Tone"
    }
  }
}

/// One node entry in a `.bulkMove` payload. Position writes are absolute,
/// not deltas, so the inverse can replay the exact origin even when the
/// model has been mutated in between by some other path (e.g. a reconcile).
struct PolicyCanvasNodeMove: Equatable {
  let id: String
  let from: CGPoint
  let to: CGPoint
}

/// One group entry in a `.bulkMove` payload. Member offsets are carried
/// explicitly so undo lands every member back at its origin instead of
/// recomputing positions from the (possibly stale) live frame.
struct PolicyCanvasGroupMove: Equatable {
  let id: String
  let fromOrigin: CGPoint
  let toOrigin: CGPoint
  let memberOrigins: [String: CGPoint]
  let memberDestinations: [String: CGPoint]
}

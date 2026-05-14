import Foundation
import SwiftUI

/// Per-pipeline viewport state persisted in `policyCanvas.byPipeline`. Holds
/// zoom + selection so each pipeline carries its own slot, instead of all
/// pipelines stomping a shared `policyCanvas.zoom` / `policyCanvas.selectionRaw`
/// key. Codable so the JSON encode/decode round-trip is straightforward.
struct PolicyCanvasPipelineSceneState: Codable, Equatable {
  var zoom: Double
  var selectionRaw: String
}

extension PolicyCanvasView {
  /// Restore zoom + selection from SceneStorage, keyed by the current
  /// `pipelineIdentity`. `nil` identity means no document has loaded yet (or
  /// the daemon has no policy trace id) - skip restoration entirely so two
  /// trace-less pipelines do not share state through a shared sentinel key.
  ///
  /// Idempotent: called from `.task` (initial mount) and from
  /// `.onChange(of: viewModel.pipelineIdentity)` (load completes after
  /// mount). If neither call has the right identity yet, the next one will.
  func restoreSceneStorageIfNeeded() {
    guard let identity = viewModel.pipelineIdentity else {
      return
    }
    let map = PolicyCanvasView.decodePipelineStateMap(storedPipelineStateRaw)
    guard let state = map[identity] else {
      return
    }
    viewModel.zoom = CGFloat(state.zoom)
    if let restoredSelection = PolicyCanvasView.decodeSelection(state.selectionRaw) {
      viewModel.selection = restoredSelection
    } else if state.selectionRaw.isEmpty {
      viewModel.selection = nil
    }
  }

  /// Persist viewport state to SceneStorage under the current
  /// `pipelineIdentity` slot. Writes are no-ops when identity is nil (don't
  /// pollute trace-less keys). Read-modify-write the JSON map so concurrent
  /// pipelines in other windows preserve their own slots.
  func persistSceneStorageIfNeeded(
    zoom: Double? = nil,
    selection: PolicyCanvasSelection?? = nil
  ) {
    guard let identity = viewModel.pipelineIdentity else {
      return
    }
    var map = PolicyCanvasView.decodePipelineStateMap(storedPipelineStateRaw)
    var state =
      map[identity]
      ?? PolicyCanvasPipelineSceneState(
        zoom: Double(viewModel.zoom),
        selectionRaw: ""
      )
    if let zoom {
      state.zoom = zoom
    }
    if let selection {
      state.selectionRaw = PolicyCanvasView.encodeSelection(selection)
    }
    map[identity] = state
    storedPipelineStateRaw = PolicyCanvasView.encodePipelineStateMap(map)
  }

  /// Encode the optional selection enum into a SceneStorage-friendly
  /// string. Empty string represents nil selection; other values use the
  /// `kind:id` form so the inverse decode is unambiguous.
  static func encodeSelection(_ selection: PolicyCanvasSelection?) -> String {
    guard let selection else {
      return ""
    }
    switch selection {
    case .node(let id):
      return "node:\(id)"
    case .edge(let id):
      return "edge:\(id)"
    case .group(let id):
      return "group:\(id)"
    }
  }

  /// Decode the SceneStorage-stored selection string. Returns nil when the
  /// raw string does not match a known prefix; callers fall back to "no
  /// selection" rather than crashing on a stale format.
  static func decodeSelection(_ raw: String) -> PolicyCanvasSelection? {
    guard let separator = raw.firstIndex(of: ":") else {
      return nil
    }
    let prefix = raw[..<separator]
    let id = String(raw[raw.index(after: separator)...])
    guard !id.isEmpty else {
      return nil
    }
    switch prefix {
    case "node":
      return .node(id)
    case "edge":
      return .edge(id)
    case "group":
      return .group(id)
    default:
      return nil
    }
  }

  /// Decode the JSON-encoded `pipelineID -> PolicyCanvasPipelineSceneState`
  /// map from SceneStorage. Returns an empty map on empty input or decode
  /// failure - this is best-effort persistence, a corrupted slot loses its
  /// scene state but does not crash or wedge the canvas.
  static func decodePipelineStateMap(_ raw: String)
    -> [String: PolicyCanvasPipelineSceneState]
  {
    guard !raw.isEmpty, let data = raw.data(using: .utf8) else {
      return [:]
    }
    return
      (try? JSONDecoder().decode(
        [String: PolicyCanvasPipelineSceneState].self,
        from: data
      )) ?? [:]
  }

  /// Encode the per-pipeline scene state map into a JSON string. Returns
  /// empty string on encode failure so SceneStorage holds a quiescent
  /// default rather than partial garbage.
  static func encodePipelineStateMap(
    _ map: [String: PolicyCanvasPipelineSceneState]
  ) -> String {
    guard
      let data = try? JSONEncoder().encode(map),
      let raw = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return raw
  }
}

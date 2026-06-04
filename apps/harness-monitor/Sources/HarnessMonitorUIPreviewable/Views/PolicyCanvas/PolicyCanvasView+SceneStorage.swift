import Foundation
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Per-pipeline viewport state persisted in `policyCanvas.byPipeline`. Holds
/// zoom, selection, and viewport origin so each pipeline carries its own slot,
/// instead of all pipelines stomping a shared `policyCanvas.zoom` /
/// `policyCanvas.selectionRaw` key. Codable so the JSON encode/decode
/// round-trip is straightforward.
struct PolicyCanvasPipelineSceneState: Codable, Equatable {
  var zoom: Double
  var selectionRaw: String
  var viewportOriginX: Double?
  var viewportOriginY: Double?
  var viewportWidth: Double?
  var viewportHeight: Double?

  var viewportOrigin: CGPoint? {
    guard let viewportOriginX, let viewportOriginY else {
      return nil
    }
    return CGPoint(x: viewportOriginX, y: viewportOriginY)
  }

  var viewportRect: CGRect? {
    guard
      let viewportOrigin,
      let viewportWidth,
      let viewportHeight
    else {
      return nil
    }
    return CGRect(
      x: viewportOrigin.x,
      y: viewportOrigin.y,
      width: viewportWidth,
      height: viewportHeight
    )
  }
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
    guard
      let state = Self.sceneState(
        for: viewModel.pipelineIdentity,
        raw: storedPipelineStateRaw,
        suppressesSceneStorage: suppressesSceneStorage
      )
    else {
      return
    }
    viewModel.zoom = PolicyCanvasViewModel.sanitizedZoom(
      CGFloat(state.zoom),
      fallback: viewModel.zoom
    )
    if let restoredSelection = Self.decodeSelection(state.selectionRaw) {
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
    selection: PolicyCanvasSelection?? = nil,
    viewportOrigin: CGPoint? = nil,
    viewportRect: CGRect? = nil,
    for identity: String? = nil
  ) {
    let targetIdentity = identity ?? viewModel.pipelineIdentity
    guard !suppressesSceneStorage, let targetIdentity else {
      return
    }
    var map = Self.decodePipelineStateMap(storedPipelineStateRaw)
    let previousState = map[targetIdentity]
    var state =
      previousState
      ?? PolicyCanvasPipelineSceneState(
        zoom: Double(viewModel.zoom),
        selectionRaw: ""
      )
    if let zoom {
      state.zoom = zoom
    }
    if let selection {
      state.selectionRaw = Self.encodeSelection(selection)
    }
    if let viewportOrigin {
      state.viewportOriginX = Double(viewportOrigin.x)
      state.viewportOriginY = Double(viewportOrigin.y)
    }
    if let viewportRect {
      state.viewportOriginX = Double(viewportRect.minX)
      state.viewportOriginY = Double(viewportRect.minY)
      state.viewportWidth = Double(viewportRect.width)
      state.viewportHeight = Double(viewportRect.height)
    }
    guard previousState != state else {
      return
    }
    map[targetIdentity] = state
    storedPipelineStateRaw = Self.encodePipelineStateMap(map)
  }

  func persistSceneStorageIfNeeded(
    _ viewportState: PolicyCanvasViewportObservedState,
    for identity: String?
  ) {
    persistSceneStorageIfNeeded(
      zoom: Double(viewportState.zoom),
      viewportRect: viewportState.visibleContentRect,
      for: identity
    )
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

  static func sceneState(
    for identity: String?,
    raw: String,
    suppressesSceneStorage: Bool = false
  ) -> PolicyCanvasPipelineSceneState? {
    guard !suppressesSceneStorage, let identity else {
      return nil
    }
    return decodePipelineStateMap(raw)[identity]
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

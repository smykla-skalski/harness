import SwiftUI

extension PolicyCanvasView {
  /// Restore zoom + selection from SceneStorage, but only when the current
  /// `pipelineIdentity` matches the stored ID. `nil` identity means no
  /// document has loaded yet (or the daemon has no policy trace id) — skip
  /// restoration entirely so two trace-less pipelines do not share state
  /// through a shared sentinel key.
  ///
  /// Idempotent: called from `.task` (initial mount) and from
  /// `.onChange(of: viewModel.pipelineIdentity)` (load completes after
  /// mount). If neither call has the right identity yet, the next one will.
  func restoreSceneStorageIfNeeded() {
    guard let identity = viewModel.pipelineIdentity else {
      return
    }
    guard !storedPipelineID.isEmpty, storedPipelineID == identity else {
      return
    }
    viewModel.zoom = CGFloat(storedZoom)
    if let restoredSelection = PolicyCanvasView.decodeSelection(storedSelectionRaw) {
      viewModel.selection = restoredSelection
    } else if storedSelectionRaw.isEmpty {
      viewModel.selection = nil
    }
  }

  /// Persist viewport state to SceneStorage. Writes are no-ops when
  /// `pipelineIdentity` is nil (don't pollute trace-less keys) or when the
  /// stored id is for a different pipeline (a restore is still pending).
  func persistSceneStorageIfNeeded(
    zoom: Double? = nil,
    selection: PolicyCanvasSelection?? = nil
  ) {
    guard let identity = viewModel.pipelineIdentity else {
      return
    }
    if storedPipelineID != identity {
      storedPipelineID = identity
    }
    if let zoom {
      storedZoom = zoom
    }
    if let selection {
      storedSelectionRaw = PolicyCanvasView.encodeSelection(selection)
    }
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
}

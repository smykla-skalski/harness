import SwiftUI

/// Trailing-edge coalescer for live route recomputation.
///
/// A node drag writes a new position every gesture tick (60 Hz). Routing the
/// whole graph per tick would either back up a queue of stale computes or thrash
/// a per-frame `.task(id:)`. Instead every tick calls `schedule(_:)`, which keeps
/// exactly one recompute in flight and, when it finishes, runs once more only if
/// further ticks arrived meanwhile - always against the latest positions, never
/// the intermediate ones. This mirrors libavoid's `Router::processTransaction()`
/// batching: collapse N queued changes into one regeneration rather than N (see
/// `.bart/research/policy-canvas-route-performance-2026-06-20/02-orthogonal-routing-performance-and-incremental-repair.md`).
///
/// The work closure snapshots the current graph itself, so dropping intermediate
/// ticks is lossless: each run reads whatever positions are current when it runs.
/// `schedule` mutates only this object's own non-observed flags, so it never
/// invalidates the view that calls it - which is what keeps it out of the
/// body-derived `.task(id:)` feedback loop that drove the prior design.
@MainActor
final class PolicyCanvasLiveRouteCoalescer {
  private var isRunning = false
  private var hasPending = false
  private var runner: Task<Void, Never>?

  /// Request a recompute. If one is already running, mark that another pass is
  /// needed and return; the in-flight runner picks it up when it finishes.
  func schedule(_ work: @escaping @MainActor () async -> Void) {
    hasPending = true
    guard !isRunning else {
      return
    }
    isRunning = true
    runner = Task { @MainActor in
      while hasPending {
        hasPending = false
        await work()
      }
      isRunning = false
    }
  }

  /// Await the current in-flight runner, if any. Test-only hook; production code
  /// drives this purely through `schedule`.
  func settle() async {
    await runner?.value
  }
}

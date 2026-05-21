import HarnessMonitorKit
import SwiftUI

#Preview("Dashboard Dependencies — PR description") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
  store.dependencyUpdateBodies.clear()
  store.dependencyUpdateBodies.store(
    pullRequestID: "preview-deps-1",
    body: DashboardDependenciesPreviewBody.octocrab,
    prUpdatedAt: "2026-03-28T14:18:00Z",
    fetchedAt: "2026-03-28T14:20:30Z"
  )
  return DashboardDependenciesRouteView(
    store: store,
    selectedRoute: .constant(.dependencies)
  )
  .frame(width: 1180, height: 780)
}

private enum DashboardDependenciesPreviewBody {
  static let octocrab = """
    Bumps `octocrab` from **0.45.0** to **0.46.0**.

    ## Highlights

    - Adds direct `node(id:)` PR lookups so single-PR fetches skip the search index.
    - Removes the deprecated `models::pull::PullRequest` re-export.
    - Tightens `Octocrab::pulls()` error variants around rate-limit retries.

    ## Verification

    1. `cargo check --all-targets`
    2. Run the dependency-updates body smoke test.
    3. Re-open the same PR — description should serve from cache without spinner.

    Closes the tracking issue and keeps the daemon's GraphQL surface current.
    """
}

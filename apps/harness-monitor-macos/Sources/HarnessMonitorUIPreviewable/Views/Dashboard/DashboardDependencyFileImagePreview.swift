import HarnessMonitorKit
import SwiftUI

/// Placeholder image preview pane for binary files. Real CGImage decode
/// happens in `DependencyUpdateImageDecoder`; this view renders the
/// current best-effort outcome and exposes an "Open on github.com"
/// affordance for assets that overflow the size budget.
struct DashboardDependencyFileImagePreview: View {
  let file: DependencyUpdateFile
  let patch: DependencyUpdateFilePatch

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Binary file", systemImage: "photo")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(
        "Image previews load lazily once the daemon's local-clone or REST blob fetch finishes. Patch metadata reports \(file.additions) additions and \(file.deletions) deletions."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if patch.truncated {
        Text("Truncated by GitHub. Open on github.com for the full asset.")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(.vertical, 6)
    .accessibilityIdentifier("dashboardDependencyFileImagePreview(\(file.path))")
  }
}

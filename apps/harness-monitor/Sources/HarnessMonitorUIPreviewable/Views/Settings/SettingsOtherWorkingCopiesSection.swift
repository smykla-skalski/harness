import HarnessMonitorKit
import SwiftUI

/// Lists the daemon-owned working copies that no repository row above offers to
/// reclaim - a repository that left the monitored list, or one now bound to a
/// folder the user picked - so their disk is visible and reclaimable instead of
/// waiting on daemon garbage collection.
struct SettingsOtherWorkingCopiesSection: View {
  let copies: [WorkingCopyListEntry]
  let reclaiming: Set<String>
  let reclaim: (String) -> Void

  var body: some View {
    Section {
      ForEach(copies, id: \.repoKeySegment) { copy in
        row(for: copy)
      }
    } header: {
      Text("Other Working Copies")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        "Copies for repositories you stopped monitoring, or that now point at a folder you "
          + "picked. Reclaim one to free its disk."
      )
      .foregroundStyle(.secondary)
    }
  }

  private func row(for copy: WorkingCopyListEntry) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(copy.repoFullName)
          .lineLimit(1)
          .truncationMode(.middle)
        Text("\(formattedSize(copy.sizeBytes)) - \(abbreviatedPath(copy.path))")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 12)
      action(for: copy)
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsOtherWorkingCopyRow(copy.repoKeySegment)
    )
  }

  @ViewBuilder
  private func action(for copy: WorkingCopyListEntry) -> some View {
    if reclaiming.contains(copy.repoKeySegment) {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel(Text("Reclaiming the working copy of \(copy.repoFullName)"))
    } else {
      Button("Reclaim", role: .destructive) { reclaim(copy.repoKeySegment) }
    }
  }

  private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  @MainActor private static let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()

  @MainActor
  private func formattedSize(_ bytes: UInt64) -> String {
    Self.byteCountFormatter.string(fromByteCount: Int64(bytes))
  }
}

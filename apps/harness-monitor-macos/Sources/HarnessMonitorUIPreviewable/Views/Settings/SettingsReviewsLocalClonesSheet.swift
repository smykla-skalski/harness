import HarnessMonitorKit
import SwiftUI

/// Lists every review local clone the daemon is maintaining
/// so the user can free disk space without inspecting the runtime path
/// directly. Calls into the store's `listReviewLocalClones`
/// and `deleteReviewLocalClone` helpers from B.8e.
struct SettingsReviewsLocalClonesSheet: View {
  @Environment(HarnessMonitorStore.self)
  private var store
  @Environment(\.dismiss)
  private var dismiss
  @State private var clones: [ReviewLocalCloneEntry] = []
  @State private var pendingDelete: ReviewLocalCloneEntry?
  @State private var isLoading = true
  /// Latest in-flight progress event per repo full-name, populated by
  /// the catch-all `observeAllLocalCloneProgress()` subscription.
  /// Cleared on `.completed` / `.failed` so the row drops the badge.
  @State private var inflightByRepo: [String: ReviewLocalCloneProgress] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      content
      footer
    }
    .padding(20)
    .frame(minWidth: 540, minHeight: 360)
    .task { await refresh() }
    .task { await observeProgress() }
    .accessibilityIdentifier("settingsReviewLocalClonesSheet")
    .alert(item: $pendingDelete) { entry in
      Alert(
        title: Text("Delete local clone?"),
        message: Text(deleteConfirmationMessage(for: entry)),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await store.deleteReviewLocalClone(
              repoKeySegment: entry.repoKeySegment
            )
            await refresh()
          }
        },
        secondaryButton: .cancel()
      )
    }
  }

  private var header: some View {
    HStack {
      Text("Local clones").font(.title3.weight(.semibold))
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
  }

  private func deleteConfirmationMessage(for entry: ReviewLocalCloneEntry) -> String {
    """
    Removing \(entry.repoFullName) frees \(humanizedBytes(entry.sizeBytes)). The next time a PR \
    for this repo opens, the daemon will re-clone it.
    """
  }

  @ViewBuilder private var content: some View {
    if isLoading {
      VStack { ProgressView() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if clones.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("No local clones cached yet").font(.headline)
        Text("Opening a substantial PR triggers a bare partial clone shared across PRs.")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Table(of: ReviewLocalCloneEntry.self) {
        TableColumn("Repo") { entry in
          HStack(spacing: 6) {
            Text(entry.repoFullName).lineLimit(1)
            inflightChip(for: entry)
          }
        }
        TableColumn("Size") { entry in
          Text(humanizedBytes(entry.sizeBytes)).monospacedDigit()
        }
        TableColumn("Last used") { entry in
          Text(entry.lastUsedAt).font(.caption.monospacedDigit())
        }
        TableColumn("Last fetched") { entry in
          Text(entry.lastFetchedAt).font(.caption.monospacedDigit())
        }
        TableColumn("") { entry in
          Button(role: .destructive) {
            pendingDelete = entry
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Delete \(entry.repoFullName)")
        }
        .width(36)
      } rows: {
        ForEach(clones) { entry in TableRow(entry) }
      }
      .frame(minHeight: 200)
    }
  }

  @ViewBuilder
  private func inflightChip(for entry: ReviewLocalCloneEntry) -> some View {
    if let progress = inflightByRepo[entry.repoFullName],
      progress.kind == .started
    {
      HStack(spacing: 4) {
        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        Text("\(progress.operation.presentLabel)…")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier(
        "settingsReviewLocalCloneProgressChip-\(entry.repoFullName)"
      )
      .accessibilityLabel("\(progress.operation.presentLabel) \(entry.repoFullName)")
    }
  }

  private var footer: some View {
    HStack {
      Text(totalsLabel).foregroundStyle(.secondary).font(.caption)
      Spacer()
      Button("Refresh") {
        Task { await refresh() }
      }
    }
  }

  private var totalsLabel: String {
    let totalBytes = clones.reduce(into: 0) { $0 += $1.sizeBytes }
    return "Using \(humanizedBytes(totalBytes)) across \(clones.count) clones"
  }

  private func refresh() async {
    isLoading = true
    clones = await store.listReviewLocalClones()
    isLoading = false
  }

  /// Catch-all progress subscription so the sheet shows in-flight
  /// clones even for repos not yet in the registry (first clone) and
  /// drops the badge when the operation completes or fails. Lives for
  /// the sheet's lifetime; cleaned up automatically via the
  /// AsyncStream's `onTermination` hook.
  private func observeProgress() async {
    for await event in store.observeAllLocalCloneProgress() {
      switch event.kind {
      case .started:
        inflightByRepo[event.repoFullName] = event
      case .completed, .failed:
        inflightByRepo.removeValue(forKey: event.repoFullName)
        // Refresh so the size / last-fetched columns reflect reality
        // immediately after a clone completes.
        if event.kind == .completed {
          await refresh()
        }
      }
    }
  }

  private func humanizedBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
  }
}

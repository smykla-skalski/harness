import HarnessMonitorKit
import SwiftUI

/// Lists every dependency-update local clone the daemon is maintaining
/// so the user can free disk space without inspecting the runtime path
/// directly. Calls into the store's `listDependencyUpdateLocalClones`
/// and `deleteDependencyUpdateLocalClone` helpers from B.8e.
struct SettingsDependenciesLocalClonesSheet: View {
  @Environment(HarnessMonitorStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var clones: [DependencyUpdateLocalCloneEntry] = []
  @State private var pendingDelete: DependencyUpdateLocalCloneEntry?
  @State private var isLoading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      content
      footer
    }
    .padding(20)
    .frame(minWidth: 540, minHeight: 360)
    .task { await refresh() }
    .accessibilityIdentifier("settingsDependencyLocalClonesSheet")
    .alert(item: $pendingDelete) { entry in
      Alert(
        title: Text("Delete local clone?"),
        message: Text(
          "Removing \(entry.repoFullName) frees \(humanizedBytes(entry.sizeBytes)). The next time a PR for this repo opens, the daemon will re-clone it."
        ),
        primaryButton: .destructive(Text("Delete")) {
          Task {
            await store.deleteDependencyUpdateLocalClone(
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

  @ViewBuilder
  private var content: some View {
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
      Table(of: DependencyUpdateLocalCloneEntry.self) {
        TableColumn("Repo") { entry in
          Text(entry.repoFullName).lineLimit(1)
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
    clones = await store.listDependencyUpdateLocalClones()
    isLoading = false
  }

  private func humanizedBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
  }
}


import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

/// Consolidated prompt for choosing local working directories for imported
/// repositories that have none. One row per repository, deduplicated upstream,
/// so items from several repositories resolve in a single pass.
struct ResolveRepositoryDirectoriesSheet: View {
  let store: HarnessMonitorStore
  let repositories: [String]

  @State private var resolved: Set<String> = []
  @State private var importingRepository: String?
  @State private var obtaining: Set<String> = []
  @State private var obtainFailed: Set<String> = []
  /// Live obtain progress per repository, fed by the catch-all
  /// `observeAllWorkingCopyProgress()` subscription. Terminal events drop the
  /// entry, returning the row to its resolved or retry state.
  @State private var progress = TaskBoardWorkingCopyProgressTracker()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      ScrollView {
        VStack(spacing: 8) {
          ForEach(Array(repositories.enumerated()), id: \.offset) { _, repository in
            row(for: repository)
          }
        }
      }
      Divider()
      footer
    }
    .padding(20)
    .task { await observeProgress() }
    .fileImporter(
      isPresented: Binding(
        get: { importingRepository != nil },
        set: { if !$0 { importingRepository = nil } }
      ),
      allowedContentTypes: [.folder]
    ) { result in
      guard let repository = importingRepository else { return }
      importingRepository = nil
      let folders = result.map { [$0] }
      Task { @MainActor in
        if await store.resolveRepositoryWorkingDirectory(repository: repository, from: folders) {
          resolved.insert(repository)
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Set working directories")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text("These imported repositories need a local folder before their items can run.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }

  private func row(for repository: String) -> some View {
    let isResolved = resolved.contains(repository)
    return HStack(spacing: 12) {
      Image(systemName: isResolved ? "checkmark.circle.fill" : "folder.badge.questionmark")
        .foregroundStyle(isResolved ? Color.green : Color.secondary)
        .accessibilityHidden(true)
      Text(repository)
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityLabel(
          Text("\(repository), \(isResolved ? "folder selected" : "no folder selected")")
        )
      Spacer(minLength: 12)
      if obtainFailed.contains(repository) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help("Could not obtain a copy - check the repository token, then retry")
          .accessibilityLabel(Text("Could not obtain a copy of \(repository)"))
      }
      if obtaining.contains(repository) {
        obtainProgress(for: repository)
      } else {
        Button("Obtain a Copy") { obtain(repository) }
          .disabled(isResolved)
          .help("Clone this repository into a daemon-managed working copy")
      }
      Button(isResolved ? "Change Folder…" : "Choose Folder…") {
        importingRepository = repository
      }
    }
    .padding(.vertical, 4)
  }

  /// Re-renders once a second so a clone that stops reporting still reads as
  /// stalled. Without the tick, silence would leave the last advancing frame on
  /// screen indefinitely.
  @ViewBuilder
  private func obtainProgress(for repository: String) -> some View {
    if let entry = progress.entry(for: repository) {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        TaskBoardWorkingCopyProgressView(
          repository: repository,
          entry: entry,
          now: context.date
        )
      }
    } else {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel(Text("Obtaining a copy of \(repository)"))
    }
  }

  private func observeProgress() async {
    for await event in store.observeAllWorkingCopyProgress() {
      progress.ingest(event, at: Date())
    }
  }

  private func obtain(_ repository: String) {
    obtaining.insert(repository)
    obtainFailed.remove(repository)
    Task { @MainActor in
      let entry = await store.obtainRepositoryWorkingCopy(repository: repository)
      obtaining.remove(repository)
      progress.forget(repository)
      if entry == nil {
        obtainFailed.insert(repository)
      } else {
        resolved.insert(repository)
      }
    }
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Done") { store.dismissSheet() }
        .keyboardShortcut(.defaultAction)
    }
  }
}

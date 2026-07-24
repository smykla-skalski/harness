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
      }
      if obtaining.contains(repository) {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(Text("Obtaining a copy of \(repository)"))
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

  private func obtain(_ repository: String) {
    obtaining.insert(repository)
    obtainFailed.remove(repository)
    Task { @MainActor in
      let entry = await store.obtainRepositoryWorkingCopy(repository: repository)
      obtaining.remove(repository)
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

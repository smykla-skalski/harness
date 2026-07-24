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

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      ScrollView {
        VStack(spacing: 8) {
          ForEach(repositories, id: \.self, content: row(for:))
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
      Task {
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
      Text(repository)
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 12)
      Button("Clone") {}
        .disabled(true)
        .help("Cloning a repository that has no local checkout comes in a later update")
      Button(isResolved ? "Change Folder…" : "Choose Folder…") {
        importingRepository = repository
      }
    }
    .padding(.vertical, 4)
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Done") { store.dismissSheet() }
        .keyboardShortcut(.defaultAction)
    }
  }
}

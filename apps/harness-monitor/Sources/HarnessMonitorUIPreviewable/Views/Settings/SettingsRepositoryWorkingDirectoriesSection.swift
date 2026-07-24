import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets the user bind each monitored repository to a local working directory up
/// front, so imported items deliver without prompting. Shares the association
/// store and folder-pick flow with the deliver-time sheet.
struct SettingsRepositoryWorkingDirectoriesSection: View {
  let store: HarnessMonitorStore
  let repositories: [String]

  @State private var paths: [String: String] = [:]
  @State private var importingRepository: String?

  var body: some View {
    Section {
      if repositories.isEmpty {
        Text("Add a repository above to choose its working directory")
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(repositories.enumerated()), id: \.offset) { _, repository in
          row(for: repository)
        }
      }
    } header: {
      Text("Working Directories")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Imported items run in the folder you choose for their repository.")
        .foregroundStyle(.secondary)
    }
    .task(id: repositories) { await reload() }
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
          await reload()
        }
      }
    }
  }

  private func row(for repository: String) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(repository)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(paths[repository].map(abbreviatedPath) ?? "Not set")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 12)
      if paths[repository] != nil {
        Button("Remove", role: .destructive) {
          Task {
            await store.removeRepositoryWorkingDirectory(repository: repository)
            await reload()
          }
        }
      }
      Button(paths[repository] == nil ? "Choose Folder…" : "Change…") {
        importingRepository = repository
      }
    }
  }

  @MainActor
  private func reload() async {
    paths = await store.repositoryWorkingDirectoryPaths()
  }

  private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

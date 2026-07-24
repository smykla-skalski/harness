import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets the user bind each monitored repository to a working directory up front,
/// so imported items deliver without prompting. A repository can either point at
/// a local folder the user picks, or a working copy the daemon obtains (clones)
/// and can reclaim to free disk. Shares the association store and folder-pick
/// flow with the deliver-time sheet.
struct SettingsRepositoryWorkingDirectoriesSection: View {
  let store: HarnessMonitorStore
  let repositories: [String]

  @State private var paths: [String: String] = [:]
  @State private var associated: Set<String> = []
  @State private var workingCopies: [String: WorkingCopyListEntry] = [:]
  @State private var obtaining: Set<String> = []
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
      Text("Imported items run in the folder you choose, or a working copy the app obtains.")
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
    let bookmarkPath = paths[repository]
    let managedCopy = workingCopies[repository.lowercased()]
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(repository)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(detail(bookmarkPath: bookmarkPath, managedCopy: managedCopy))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 12)
      actions(for: repository, bookmarkPath: bookmarkPath, managedCopy: managedCopy)
    }
  }

  @ViewBuilder
  private func actions(
    for repository: String,
    bookmarkPath: String?,
    managedCopy: WorkingCopyListEntry?
  ) -> some View {
    if obtaining.contains(repository) {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel(Text("Obtaining a copy of \(repository)"))
    } else {
      if associated.contains(repository) {
        Button("Remove", role: .destructive) {
          Task {
            await store.removeRepositoryWorkingDirectory(repository: repository)
            await reload()
          }
        }
      } else if let managedCopy {
        Button("Reclaim", role: .destructive) { reclaim(managedCopy.repoKeySegment) }
      } else {
        Button("Obtain a Copy") { obtain(repository) }
      }
      Button(bookmarkPath == nil && managedCopy == nil ? "Choose Folder…" : "Change…") {
        importingRepository = repository
      }
    }
  }

  private func detail(bookmarkPath: String?, managedCopy: WorkingCopyListEntry?) -> String {
    if let bookmarkPath {
      return abbreviatedPath(bookmarkPath)
    }
    if let managedCopy {
      return "Working copy - \(formattedSize(managedCopy.sizeBytes))"
    }
    return "Not set"
  }

  private func obtain(_ repository: String) {
    obtaining.insert(repository)
    Task { @MainActor in
      _ = await store.obtainRepositoryWorkingCopy(repository: repository)
      obtaining.remove(repository)
      await reload()
    }
  }

  private func reclaim(_ repoKeySegment: String) {
    Task {
      await store.deleteRepositoryWorkingCopy(repoKeySegment: repoKeySegment)
      await reload()
    }
  }

  @MainActor
  private func reload() async {
    paths = await store.repositoryWorkingDirectoryPaths()
    associated = await store.repositoryDirectoryAssociations()
    let copies = await store.listRepositoryWorkingCopies()
    workingCopies = Dictionary(
      copies.map { ($0.repoFullName.lowercased(), $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  nonisolated(unsafe) private static let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()

  private func formattedSize(_ bytes: UInt64) -> String {
    Self.byteCountFormatter.string(fromByteCount: Int64(bytes))
  }
}

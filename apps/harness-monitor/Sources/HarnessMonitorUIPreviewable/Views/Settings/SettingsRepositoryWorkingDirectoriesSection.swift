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
  @State private var otherCopies: [WorkingCopyListEntry] = []
  @State private var obtaining: Set<String> = []
  @State private var reclaiming: Set<String> = []
  @State private var importingRepository: String?
  /// Live obtain progress per repository, fed by the catch-all
  /// `observeAllWorkingCopyProgress()` subscription. Terminal events drop the
  /// entry, returning the row to its resolved or retry state.
  @State private var progress = TaskBoardWorkingCopyProgressTracker()

  var body: some View {
    directoriesSection
    if !otherCopies.isEmpty {
      SettingsOtherWorkingCopiesSection(
        copies: otherCopies,
        reclaiming: reclaiming,
        reclaim: reclaim
      )
    }
  }

  private var directoriesSection: some View {
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
      Task {
        if await store.resolveRepositoryWorkingDirectory(repository: repository, from: folders) {
          await reload()
        }
      }
    }
  }

  private func row(for repository: String) -> some View {
    // paths/associated/workingCopies are keyed by the normalized slug (the
    // association store trims + lowercases on write); a mixed-case display
    // string must be normalized before lookup or the row shows "Not set".
    let key = RepositoryDirectoryStore.normalizedRepository(repository)
    let bookmarkPath = paths[key]
    let managedCopy = workingCopies[key]
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
      actions(
        for: repository,
        isAssociated: associated.contains(key),
        bookmarkPath: bookmarkPath,
        managedCopy: managedCopy
      )
    }
  }

  @ViewBuilder
  private func actions(
    for repository: String,
    isAssociated: Bool,
    bookmarkPath: String?,
    managedCopy: WorkingCopyListEntry?
  ) -> some View {
    if obtaining.contains(repository) {
      obtainProgress(for: repository)
    } else {
      if isAssociated {
        Button("Remove", role: .destructive) {
          Task {
            await store.removeRepositoryWorkingDirectory(repository: repository)
            await reload()
          }
        }
      } else if let managedCopy {
        Button("Reclaim", role: .destructive) { reclaim(managedCopy.repoKeySegment) }
          .disabled(reclaiming.contains(managedCopy.repoKeySegment))
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
    Task { @MainActor in
      _ = await store.obtainRepositoryWorkingCopy(repository: repository)
      obtaining.remove(repository)
      progress.forget(repository)
      await reload()
    }
  }

  private func reclaim(_ repoKeySegment: String) {
    reclaiming.insert(repoKeySegment)
    Task { @MainActor in
      await store.deleteRepositoryWorkingCopy(repoKeySegment: repoKeySegment)
      reclaiming.remove(repoKeySegment)
      await reload()
    }
  }

  @MainActor
  private func reload() async {
    paths = await store.repositoryWorkingDirectoryPaths()
    associated = await store.repositoryDirectoryAssociations()
    let inventory = RepositoryWorkingCopyInventory(
      copies: await store.listRepositoryWorkingCopies(),
      monitoredRepositories: repositories,
      associatedRepositories: associated
    )
    workingCopies = inventory.byRepository
    otherCopies = inventory.unlisted
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

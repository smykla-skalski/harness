import AppKit
import HarnessMonitorKit
import SwiftUI

public struct AuthorizedFoldersSection: View {
  public let store: HarnessMonitorStore
  public let isActive: Bool

  public init(store: HarnessMonitorStore, isActive: Bool = true) {
    self.store = store
    self.isActive = isActive
  }

  @State private var records: [BookmarkStore.Record] = []
  @State private var cachedBookmarkStore: BookmarkStore?

  public var body: some View {
    let activeBookmarkStore = isActive ? store.bookmarkStore : nil
    let bookmarkStore = activeBookmarkStore ?? cachedBookmarkStore
    Form {
      foldersSection(bookmarkStore: bookmarkStore)
    }
    .settingsDetailFormStyle()
    .task(id: isActive) {
      guard isActive else { return }
      cachedBookmarkStore = activeBookmarkStore
      await reload(bookmarkStore: activeBookmarkStore)
    }
  }

  // MARK: - Sections

  private func foldersSection(bookmarkStore: BookmarkStore?) -> some View {
    Section {
      foldersContent(bookmarkStore: bookmarkStore)
      HarnessMonitorActionButton(
        title: "Add Folder…",
        tint: nil,
        variant: .bordered,
        accessibilityIdentifier: HarnessMonitorAccessibility
          .settingsAuthorizedFoldersAddButton
      ) {
        store.requestOpenFolder()
      }
      .disabled(bookmarkStore == nil)
    } header: {
      Text("Authorized Folders")
    }
  }

  @ViewBuilder private func foldersContent(bookmarkStore: BookmarkStore?) -> some View {
    if bookmarkStore == nil {
      ContentUnavailableView(
        "Bookmark store unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text(
          "The app group container is not available; authorized folders cannot be managed"
        )
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsAuthorizedFoldersUnavailable
      )
    } else if records.isEmpty {
      ContentUnavailableView(
        "No authorized folders",
        systemImage: "folder.badge.questionmark",
        description: Text("Use File > Open Folder… to authorize a project directory")
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsAuthorizedFoldersEmpty
      )
    } else {
      ForEach(records, id: \.id) { record in
        folderRow(for: record, bookmarkStore: bookmarkStore)
      }
    }
  }

  // MARK: - Row

  private func folderRow(
    for record: BookmarkStore.Record,
    bookmarkStore: BookmarkStore?
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(record.displayName)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      Text(abbreviateHomePath(record.lastResolvedPath))
        .scaledFont(.caption.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .trailing)
      Menu {
        Button("Reveal in Finder") {
          Task { await reveal(record, bookmarkStore: bookmarkStore) }
        }
        Button("Remove", role: .destructive) {
          Task { await remove(record, bookmarkStore: bookmarkStore) }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("\(record.displayName), \(record.lastResolvedPath)"))
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsAuthorizedFolderRow(record.id)
    )
  }

  // MARK: - Actions

  private func reload(bookmarkStore: BookmarkStore?) async {
    guard let bookmarkStore else {
      records = []
      return
    }
    records = await bookmarkStore.all().filter {
      $0.kind == .projectRoot || $0.kind == .sessionDirectory
    }
  }

  private func remove(_ record: BookmarkStore.Record, bookmarkStore: BookmarkStore?) async {
    guard let bookmarkStore else { return }
    do {
      try await bookmarkStore.remove(id: record.id)
      await reload(bookmarkStore: bookmarkStore)
    } catch {
      store.presentFailureFeedback(
        "Could not remove folder: \(error.localizedDescription)"
      )
    }
  }

  private func reveal(_ record: BookmarkStore.Record, bookmarkStore: BookmarkStore?) async {
    guard let bookmarkStore else { return }
    do {
      let resolved = try await bookmarkStore.resolve(id: record.id)
      NSWorkspace.shared.activateFileViewerSelecting([resolved.url])
      if resolved.isStale {
        await reload(bookmarkStore: bookmarkStore)
      }
    } catch {
      store.presentFailureFeedback(
        "Could not reveal folder: \(error.localizedDescription)"
      )
    }
  }
}

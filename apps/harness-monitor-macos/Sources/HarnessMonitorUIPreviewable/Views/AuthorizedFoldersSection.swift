import AppKit
import HarnessMonitorKit
import SwiftUI

public struct AuthorizedFoldersSection: View {
  public let store: HarnessMonitorStore

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  @State private var records: [BookmarkStore.Record] = []

  public var body: some View {
    Form {
      foldersSection
    }
    .preferencesDetailFormStyle()
    .task { await reload() }
  }

  // MARK: - Sections

  private var foldersSection: some View {
    Section {
      foldersContent
      HarnessMonitorActionButton(
        title: "Add Folder…",
        tint: nil,
        variant: .bordered,
        accessibilityIdentifier: HarnessMonitorAccessibility
          .preferencesAuthorizedFoldersAddButton
      ) {
        store.requestOpenFolder()
      }
      .disabled(store.bookmarkStore == nil)
    } header: {
      Text("Authorized Folders")
    }
  }

  @ViewBuilder private var foldersContent: some View {
    if store.bookmarkStore == nil {
      ContentUnavailableView(
        "Bookmark store unavailable",
        systemImage: "exclamationmark.triangle",
        description: Text(
          "The app group container is not available; authorized folders cannot be managed."
        )
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesAuthorizedFoldersUnavailable
      )
    } else if records.isEmpty {
      ContentUnavailableView(
        "No authorized folders",
        systemImage: "folder.badge.questionmark",
        description: Text("Use File > Open Folder… to authorize a project directory.")
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesAuthorizedFoldersEmpty
      )
    } else {
      ForEach(records, id: \.id) { record in
        folderRow(for: record)
      }
    }
  }

  // MARK: - Row

  private func folderRow(for record: BookmarkStore.Record) -> some View {
    LabeledContent(record.displayName) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Text(abbreviateHomePath(record.lastResolvedPath))
          .scaledFont(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Menu {
          Button("Reveal in Finder") {
            Task { await reveal(record) }
          }
          Button("Remove", role: .destructive) {
            Task { await remove(record) }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesAuthorizedFolderRow(record.id)
    )
  }

  // MARK: - Actions

  private func reload() async {
    guard let bookmarkStore = store.bookmarkStore else {
      records = []
      return
    }
    records = await bookmarkStore.all()
  }

  private func remove(_ record: BookmarkStore.Record) async {
    guard let bookmarkStore = store.bookmarkStore else { return }
    do {
      try await bookmarkStore.remove(id: record.id)
      await reload()
    } catch {
      store.presentFailureFeedback(
        "Could not remove folder: \(error.localizedDescription)"
      )
    }
  }

  private func reveal(_ record: BookmarkStore.Record) async {
    guard let bookmarkStore = store.bookmarkStore else { return }
    do {
      let resolved = try await bookmarkStore.resolve(id: record.id)
      NSWorkspace.shared.activateFileViewerSelecting([resolved.url])
      if resolved.isStale {
        await reload()
      }
    } catch {
      store.presentFailureFeedback(
        "Could not reveal folder: \(error.localizedDescription)"
      )
    }
  }
}

// MARK: - Preview

#Preview("Authorized Folders Section - Empty") {
  AuthorizedFoldersSection(store: PreferencesPreviewSupport.makeStore())
    .frame(width: 720)
}

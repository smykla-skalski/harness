import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NewSessionSheetView: View {
  private enum Field: Hashable {
    case title
    case context
    case baseRef
  }

  let store: HarnessMonitorStore
  @Bindable var viewModel: NewSessionViewModel
  @Environment(\.dismiss)
  private var dismiss
  @State private var bookmarks: [BookmarkStore.Record] = []
  @State private var showImporter = false
  @FocusState private var focusedField: Field?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      formContent
      Divider()
      footer
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionSheet)
    .task { await refreshBookmarks() }
    .onChange(of: viewModel.selectedBookmarkId) { _, newValue in
      guard newValue != nil, viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      focusedField = .title
    }
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      Task {
        if let importedBookmark = await store.handleImportedFolder(result) {
          viewModel.selectedBookmarkId = importedBookmark.id
        }
        await refreshBookmarks()
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("New Session")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text("Start a harness session in a project folder")
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Form

  private var formContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      Form {
        projectSection
        detailsSection
        advancedSection
      }
      .harnessNativeFormContainer()

      if let error = viewModel.lastError {
        errorBanner(for: error)
          .padding(.horizontal, HarnessMonitorTheme.spacingLG)
          .padding(.bottom, HarnessMonitorTheme.spacingSM)
      }
    }
  }

  private var projectSection: some View {
    Section {
      LabeledContent("Project folder") {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          Picker("Project folder", selection: $viewModel.selectedBookmarkId) {
            Text("Choose a folder…").tag(String?.none)
            ForEach(bookmarks, id: \.id) { record in
              Text(record.displayName)
                .tag(Optional(record.id))
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .harnessNativeFormControl()
          .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionProjectPicker)

          Button("Add Folder…") {
            showImporter = true
          }
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        }
      }

      if let selectedBookmark {
        LabeledContent("Path") {
          Text(abbreviateHomePath(selectedBookmark.lastResolvedPath))
            .scaledFont(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .textSelection(.enabled)
        }
      }
    } footer: {
      Text("Choose a Git project folder to start a session.")
    }
  }

  private var detailsSection: some View {
    Section {
      LabeledContent("Session title") {
        TextField("Short summary", text: $viewModel.title)
          .harnessNativeFormControl()
          .focused($focusedField, equals: .title)
          .submitLabel(.next)
          .onSubmit { focusedField = .context }
          .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionTitle)
      }

      LabeledContent("Context") {
        TextField(
          "Optional goals, links, or handoff notes",
          text: $viewModel.context,
          axis: .vertical
        )
        .harnessNativeFormControl()
        .focused($focusedField, equals: .context)
        .lineLimit(4, reservesSpace: true)
        .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionContext)
      }
    } footer: {
      Text("Title is required. Context is optional and supports multiline notes.")
    }
  }

  private var advancedSection: some View {
    Section {
      LabeledContent("Base ref") {
        TextField("origin/main", text: $viewModel.baseRef)
          .harnessNativeFormControl()
          .focused($focusedField, equals: .baseRef)
          .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionBaseRef)
      }
    } header: {
      Text("Advanced")
    } footer: {
      Text("Leave blank to use the default branch.")
    }
  }

  private func errorBanner(for error: NewSessionViewModel.SubmitError) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(HarnessMonitorTheme.danger)
      Text(errorMessage(for: error))
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionErrorBanner)
  }

  private func errorMessage(for error: NewSessionViewModel.SubmitError) -> String {
    switch error {
    case .validation(.titleRequired):
      return "A session title is required."
    case .validation(.projectRequired):
      return "Select a project folder to continue."
    case .bookmarkRevoked(let id):
      return "Access to folder \"\(id)\" was revoked. Re-add it via Add Folder\u{2026}"
    case .bookmarkStale(let id):
      return "Bookmark for \"\(id)\" is stale. Re-add the folder and try again."
    case .daemonUnreachable:
      return "The harness daemon is not reachable. Start it and try again."
    case .invalidProject:
      return """
        The selected folder is not a Git checkout with a valid HEAD.
        Create an initial commit or choose a different folder.
        """
    case .worktreeCreateFailed(let reason):
      return "Could not create the session worktree: \(reason)"
    case .invalidBaseRef(let ref, _):
      return "The base ref \"\(ref)\" could not be resolved."
    case .unexpected(let message):
      return "Unexpected error: \(message)"
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCancelButton)
      Spacer()
      Button("Create") {
        Task { await submitAndDismiss() }
      }
      .keyboardShortcut(.defaultAction)
      .harnessActionButtonStyle(variant: .prominent, tint: nil)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(!canCreate)
      .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCreateButton)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private var canCreate: Bool {
    !viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && viewModel.selectedBookmarkId != nil
      && !viewModel.isSubmitting
  }

  private var selectedBookmark: BookmarkStore.Record? {
    bookmarks.first { $0.id == viewModel.selectedBookmarkId }
  }

  private func submitAndDismiss() async {
    let result = await viewModel.submit()
    if case .success = result {
      dismiss()
    }
  }

  private func refreshBookmarks() async {
    let availableBookmarks = await viewModel.availableBookmarks()
    bookmarks = availableBookmarks

    if let selectedBookmarkId = viewModel.selectedBookmarkId,
      availableBookmarks.contains(where: { $0.id == selectedBookmarkId }) == false
    {
      viewModel.selectedBookmarkId = nil
    }

    if viewModel.selectedBookmarkId == nil, availableBookmarks.count == 1 {
      viewModel.selectedBookmarkId = availableBookmarks[0].id
    }
  }
}

// MARK: - Preview

#Preview("New Session Sheet") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(
    for: .dashboardLoaded,
    modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
  )
  let viewModel = NewSessionViewModel(
    store: store,
    bookmarkStore: BookmarkStore(
      containerURL: FileManager.default.temporaryDirectory
    ),
    client: PreviewHarnessClient(fixtures: .populated, isLaunchAgentInstalled: true)
  )
  NewSessionSheetView(store: store, viewModel: viewModel)
    .frame(width: 520)
    .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
}

import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NewSessionSheetView: View {
  let store: HarnessMonitorStore
  @Bindable var viewModel: NewSessionViewModel
  @Environment(\.dismiss)
  private var dismiss
  @State private var bookmarks: [BookmarkStore.Record] = []
  @State private var isAdvancedExpanded = false
  @State private var showImporter = false

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
    .task { bookmarks = await viewModel.availableBookmarks() }
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      Task {
        await store.handleImportedFolder(result)
        bookmarks = await viewModel.availableBookmarks()
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
        DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
          advancedContent
        }
      }
      if let error = viewModel.lastError {
        errorBanner(for: error)
          .padding(.horizontal, HarnessMonitorTheme.spacingLG)
          .padding(.bottom, HarnessMonitorTheme.spacingSM)
      }
    }
  }

  private var projectSection: some View {
    Section("Project") {
      Picker("Project", selection: $viewModel.selectedBookmarkId) {
        Text("Select a folder…").tag(String?.none)
        ForEach(bookmarks, id: \.id) { record in
          VStack(alignment: .leading, spacing: 2) {
            Text(record.displayName)
            Text(record.lastResolvedPath)
              .scaledFont(.caption.monospaced())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          }
          .tag(Optional(record.id))
        }
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionProjectPicker)
      Button("Add Folder…") {
        showImporter = true
      }
      .harnessActionButtonStyle(variant: .borderless, tint: HarnessMonitorTheme.accent)
      .scaledFont(.callout)
    }
  }

  private var detailsSection: some View {
    Section("Details") {
      TextField("Session title", text: $viewModel.title)
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionTitle)
      TextEditor(text: $viewModel.context)
        .harnessNativeFormControl()
        .frame(minHeight: 60)
        .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionContext)
    }
  }

  private var advancedContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TextField("origin/HEAD", text: $viewModel.baseRef)
        .harnessNativeFormControl()
        .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionBaseRef)
      Text("Leave blank for the default branch")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(.top, HarnessMonitorTheme.spacingXS)
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
    case .validation(.bookmarkUnavailable):
      return "The bookmark store is unavailable."
    case .bookmarkRevoked(let id):
      return "Access to folder \"\(id)\" was revoked. Re-add it via Add Folder\u{2026}"
    case .bookmarkStale(let id):
      return "Bookmark for \"\(id)\" is stale. Re-add the folder and try again."
    case .daemonUnreachable:
      return "The harness daemon is not reachable. Start it and try again."
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

  private func submitAndDismiss() async {
    let result = await viewModel.submit()
    if case .success = result {
      dismiss()
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

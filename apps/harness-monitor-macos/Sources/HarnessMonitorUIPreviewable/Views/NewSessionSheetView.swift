import AppKit
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
        if let importedBookmark = await store.handleImportedFolder(result) {
          viewModel.selectedBookmarkId = importedBookmark.id
        }
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
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        projectSection
        detailsSection
        advancedSection
        if let error = viewModel.lastError {
          errorBanner(for: error)
        }
      }
      .padding(HarnessMonitorTheme.spacingLG)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var projectSection: some View {
    NewSessionSectionCard(
      footer: "Choose a Git project folder to start a session"
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        NewSessionFieldLabel("Project folder")
        NewSessionFieldSurface {
          Picker("Project folder", selection: $viewModel.selectedBookmarkId) {
            Text("Choose a folder…").tag(String?.none)
            ForEach(bookmarks, id: \.id) { record in
              Text(record.displayName)
                .tag(Optional(record.id))
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
          .harnessNativeFormControl()
          .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionProjectPicker)
        }

        if let selectedBookmark {
          HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
            Text("Path")
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
              .frame(width: 34, alignment: .leading)

          Text(abbreviateHomePath(selectedBookmark.lastResolvedPath))
            .scaledFont(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .layoutPriority(1)
          }
        }

        Button("Add Folder…") {
          showImporter = true
        }
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }
    }
  }

  private var detailsSection: some View {
    NewSessionSectionCard {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          NewSessionFieldLabel("Session title")
          NewSessionFieldSurface {
            TextField("", text: $viewModel.title)
              .harnessNativeFormControl()
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionTitle)
          }
        }

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          NewSessionFieldLabel("Context")
          NewSessionTextArea(
            text: $viewModel.context,
            accessibilityIdentifier: HarnessMonitorAccessibility.newSessionContext
          )
        }
      }
    }
  }

  private var advancedSection: some View {
    NewSessionSectionCard(
      title: "Advanced",
      footer: "Leave blank to use the default branch."
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        NewSessionFieldLabel("Base ref")
        NewSessionFieldSurface {
          TextField("", text: $viewModel.baseRef)
            .harnessNativeFormControl()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionBaseRef)
        }
      }
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
}

private struct NewSessionSectionCard<Content: View>: View {
  let title: String?
  let footer: String?
  @ViewBuilder let content: Content

  init(
    title: String? = nil,
    footer: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let title {
        Text(title)
          .scaledFont(.headline)
          .foregroundStyle(HarnessMonitorTheme.ink)
      }

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        content
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .background(sectionBackground, in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
          .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.28), lineWidth: 1)
      }

      if let footer {
        Text(footer)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
  }

  private var sectionBackground: Color {
    Color(nsColor: .windowBackgroundColor).opacity(0.36)
  }
}

private struct NewSessionFieldLabel: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .scaledFont(.headline)
      .foregroundStyle(HarnessMonitorTheme.ink)
  }
}

private struct NewSessionFieldSurface<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background(fieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.52), lineWidth: 1)
      }
  }

  private var fieldBackground: Color {
    Color(nsColor: .controlBackgroundColor)
  }
}

private struct NewSessionTextArea: View {
  @Binding var text: String
  let accessibilityIdentifier: String

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))

      TextEditor(text: $text)
        .harnessNativeFormControl()
        .scrollContentBackground(.hidden)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
    .frame(minHeight: 112)
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.52), lineWidth: 1)
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

import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NewSessionSheetView: View {
  enum Field: Hashable {
    case title
    case context
    case baseRef
  }

  let store: HarnessMonitorStore
  @Bindable var viewModel: NewSessionViewModel
  @Environment(\.dismiss)
  var dismiss
  @Environment(\.openWindow)
  var openWindow
  @State private var bookmarks: [BookmarkStore.Record] = []
  @State private var availableAcpAgents: [AcpAgentDescriptor] = []
  @State private var runtimeProbeResults: AcpRuntimeProbeResponse?
  @State private var selectedLaunchSelection =
    HarnessMonitorAgentLaunchDefaults.preferredSelection()
  @State private var didPickLaunchSelectionManually = false
  @State private var showImporter = false
  @FocusState var focusedField: Field?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      formContent
      Divider()
      footer
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionSheet)
    .task {
      async let bookmarkRefresh: Void = refreshBookmarks()
      async let pickerCatalogRefresh: Void = loadAgentPickerCatalogs()
      _ = await bookmarkRefresh
      _ = await pickerCatalogRefresh
      normalizePreferredSelection()
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

  var header: some View {
    HarnessMonitorActionHeader(
      title: "New Session",
      subtitle: "Start a harness session in a project folder"
    )
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Form

  var formContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        createSessionContent

        if let error = viewModel.lastError {
          errorBanner(for: error)
        }
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  var createSessionContent: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
      projectSection
      detailsSection
      preferredLeaderSection
      advancedSection
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCreatePanel)
  }

  var projectSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      fieldLabel("Project folder")

      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
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
        .harnessActionButtonStyle(variant: .bordered)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      }

      if let selectedBookmark {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Text("Path")
            .fixedSize(horizontal: true, vertical: false)
          Text(abbreviateHomePath(selectedBookmark.lastResolvedPath))
            .scaledFont(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Path: \(selectedBookmark.lastResolvedPath)"))
      } else {
        fieldHelp("Choose a Git project folder to start a session")
      }
    }
  }

  var detailsSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      fieldBlock(
        "Session title",
        help: "Required. Keep it short so it stays readable in the sidebar and session history"
      ) {
        TextField("Short summary", text: $viewModel.title)
          .harnessNativeFormControl()
          .focused($focusedField, equals: .title)
          .submitLabel(.next)
          .onSubmit { focusedField = .context }
          .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionTitle)
      }

      fieldBlock(
        "Context",
        help: "Optional goals, links, or handoff notes. Multiline input stays enabled"
      ) {
        HarnessMonitorMultilineTextField(
          placeholder: "Optional goals, links, or handoff notes",
          text: $viewModel.context,
          minHeight: 84,
          focusedField: $focusedField,
          equals: .context,
          accessibilityLabel: "Context",
          accessibilityHint:
            "Optional goals, links, or handoff notes. Multiline input stays enabled"
        )
        .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionContext)
      }
    }
  }

  var advancedSection: some View {
    fieldBlock(
      "Base ref",
      help: "Optional. Leave blank to use the repository default branch"
    ) {
      TextField("main", text: $viewModel.baseRef)
        .harnessNativeFormControl()
        .focused($focusedField, equals: .baseRef)
        .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionBaseRef)
    }
  }

  var agentCapabilityOptions: [AgentCapabilityOption] {
    AgentCapabilityCatalog.options(
      acpAgents: availableAcpAgents,
      runtimeProbeResults: runtimeProbeResults,
      sandboxed: store.daemonStatus?.manifest?.sandboxed == true,
      acpHostBridgeReady: store.hostBridgeCapabilityState(for: "acp") == .ready,
      codexHostBridgeReady: store.hostBridgeCapabilityState(for: "codex") == .ready
    )
  }

  var preferredLaunchSelection: AgentLaunchSelection {
    selectedLaunchSelection
  }

  var preferredLaunchSelectionBinding: Binding<AgentLaunchSelection> {
    Binding(
      get: { selectedLaunchSelection },
      set: { newValue in
        didPickLaunchSelectionManually = true
        selectedLaunchSelection = newValue
        HarnessMonitorAgentLaunchDefaults.persist(newValue)
      }
    )
  }

  func fieldBlock<Content: View>(
    _ title: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      fieldLabel(title)
      content()

      if let help {
        fieldHelp(help)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  func fieldLabel(_ title: String) -> some View {
    Text(title)
      .scaledFont(.caption.bold())
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
  }

  func fieldHelp(_ text: String) -> some View {
    Text(text)
      .scaledFont(.caption)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .fixedSize(horizontal: false, vertical: true)
  }

  func errorBanner(for error: NewSessionViewModel.SubmitError) -> some View {
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

  func errorMessage(for error: NewSessionViewModel.SubmitError) -> String {
    switch error {
    case .validation(.titleRequired):
      return "A session title is required"
    case .validation(.projectRequired):
      return "Select a project folder to continue"
    case .bookmarkRevoked(let id):
      return "Access to folder \"\(id)\" was revoked. Re-add it via Add Folder\u{2026}"
    case .bookmarkStale(let id):
      return "Bookmark for \"\(id)\" is stale. Re-add the folder and try again"
    case .daemonUnreachable:
      return "The harness daemon is not reachable. Start it and try again"
    case .invalidProject:
      return """
        The selected folder is not a Git checkout with a valid HEAD.
        Create an initial commit or choose a different folder.
        """
    case .worktreeCreateFailed(let reason):
      return "Could not create the session worktree: \(reason)"
    case .invalidBaseRef(let ref, _):
      return "The base ref \"\(ref)\" could not be resolved"
    case .unexpected(let message):
      return "Unexpected error: \(message)"
    }
  }

  // MARK: - Footer

  var footer: some View {
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
      .accessibilityValue(createDisabledReason ?? "Ready")
      .accessibilityHint(createDisabledReason ?? "Create a new session")
      .accessibilityIdentifier(HarnessMonitorAccessibility.newSessionCreateButton)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  var canCreate: Bool {
    !viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && viewModel.selectedBookmarkId != nil
      && !viewModel.isSubmitting
  }

  var createDisabledReason: String? {
    if viewModel.isSubmitting {
      return "Creating session…"
    }

    if viewModel.selectedBookmarkId == nil {
      return "Select a project folder to enable Create"
    }

    if viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Session title is required"
    }

    return nil
  }

  var selectedBookmark: BookmarkStore.Record? {
    bookmarks.first { $0.id == viewModel.selectedBookmarkId }
  }

  @MainActor
  func submitAndDismiss() async {
    let result = await viewModel.submit(
      preferredLaunchSelectionStorageKey: selectedLaunchSelection.storageKey
    )
    guard case .success(let startedSession) = result else {
      return
    }
    HarnessMonitorAgentLaunchDefaults.persist(selectedLaunchSelection)
    // Release the attached sheet before routing so the created session window
    // can take focus instead of the presenting window reclaiming it.
    dismiss()
    await Task.yield()
    openWindow.openHarnessSessionWindow(sessionID: startedSession.sessionId)
  }

  func refreshBookmarks() async {
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

  func loadAgentPickerCatalogs() async {
    async let descriptors = store.fetchAcpAgentDescriptors()
    async let probes = store.fetchRuntimeProbeResults()
    availableAcpAgents = await descriptors
    runtimeProbeResults = await probes
  }

  func normalizePreferredSelection() {
    let options = agentCapabilityOptions
    if didPickLaunchSelectionManually {
      selectedLaunchSelection = AgentCapabilityCatalog.normalizedLaunchSelection(
        options: options,
        selection: selectedLaunchSelection,
        fallbackRuntime: selectedLaunchSelection.preferredRuntime
      )
      return
    }

    if let preferredProviderID = HarnessMonitorAgentLaunchDefaults.preferredProviderID() {
      selectedLaunchSelection = AgentCapabilityCatalog.defaultLaunchSelection(
        providerID: preferredProviderID,
        options: options,
        fallback: selectedLaunchSelection
      )
      return
    }

    selectedLaunchSelection = AgentCapabilityCatalog.firstProviderLaunchSelection(
      options: options,
      fallback: selectedLaunchSelection
    )
  }
}
